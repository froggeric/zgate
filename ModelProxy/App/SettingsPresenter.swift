import AppKit

/// Opens the Settings scene from the menu-bar panel and puts it in FRONT.
///
/// Why this exists (2026-11-23). ZGate is a menu-bar app (`LSUIElement`,
/// accessory activation policy), and such an app holds the foreground only
/// "on loan" while its panel is up. A `SettingsLink` inside the panel left
/// the panel open and the Settings window behind every other app's window —
/// and once the panel closes, the system hands activation straight back to
/// the previous app, so a plain `NSApp.activate()` never holds. Measured on
/// macOS 27 in a throwaway harness: every activate-only variant (immediate,
/// delayed, `ignoringOtherApps`, `NSRunningApplication.activate`) ended with
/// the previous app frontmost. What holds: present as a REGULAR app for as
/// long as the Settings window is open — ZGate shows a Dock icon and a menu
/// bar meanwhile — and return to the starting policy when it closes.
///
/// The panel is closed through the `dismiss` action the caller hands in:
/// SwiftUI's own, never `NSWindow.close()`. Closing the window behind
/// SwiftUI's back leaves MenuBarExtra believing the panel is still
/// presented, and the user's next click on the menu bar icon is swallowed
/// (seen in the harness and on the real app: first click dead).
@MainActor
final class SettingsPresenter {

    struct Deps {
        var policy: @MainActor () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() }
        var setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }
        var activate: @MainActor () -> Void = { NSApp.activate() }
        var windows: @MainActor () -> [NSWindow] = { NSApp.windows }
        /// Main-loop hops (the scene's window appears on a later turn); tests
        /// run them synchronously.
        var async: @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        }
        var asyncAfter: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                work()
            }
        }
    }

    /// The one presenter: MenuBarExtra rebuilds the popover on every open,
    /// so this state has to outlive the view.
    static let shared = SettingsPresenter()

    /// The SwiftUI Settings scene's window identifier.
    nonisolated static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    /// Main-loop turns `raise` waits for the scene's window before giving up.
    nonisolated static let raiseAttempts = 3
    nonisolated static let raiseRetryDelay: TimeInterval = 0.2

    /// After the close, the policy is read again at each of these delays.
    nonisolated static let settleChecks: [TimeInterval] = [0.25, 0.75, 2]

    private let deps: Deps
    /// True from `present` until the Settings window closes — or fails to
    /// appear at all.
    private(set) var isPresenting = false
    /// The policy the app ran with before the first presentation: restored,
    /// never assumed, and kept for the checks that follow a close.
    private var startingPolicy: NSApplication.ActivationPolicy?
    private var closeObserver: NSObjectProtocol?

    init(deps: Deps = Deps()) {
        self.deps = deps
    }

    nonisolated static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == settingsWindowID }
    }

    /// Called from a control INSIDE the menu-bar panel.
    /// - Parameters:
    ///   - dismiss: the view's `\.dismiss` action. Runs first — it is what
    ///     closes the panel, and it is a parameter so no caller can forget it.
    ///   - open: opens the Settings scene (`\.openSettings`).
    func present(
        dismiss: @escaping @MainActor () -> Void,
        open: @escaping @MainActor () -> Void
    ) {
        dismiss()
        if startingPolicy == nil {
            startingPolicy = deps.policy()
        }
        isPresenting = true
        deps.setPolicy(.regular)
        open()
        deps.activate()
        deps.async { [weak self] in self?.raise(attempt: 0) }
    }

    private func raise(attempt: Int) {
        if let window = Self.settingsWindow(in: deps.windows()) {
            window.makeKeyAndOrderFront(nil)
            watchClose(of: window)
            return
        }
        guard attempt + 1 < Self.raiseAttempts else {
            // Settings never appeared: give the policy back rather than leave
            // a Dock icon behind for the rest of the session.
            handleSettingsWillClose()
            return
        }
        deps.asyncAfter(Self.raiseRetryDelay) { [weak self] in
            self?.raise(attempt: attempt + 1)
        }
    }

    private func watchClose(of window: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSettingsWillClose() }
        }
    }

    /// The Settings window is closing (or never came): back to the policy
    /// the app started from — exactly once per presentation — and again if
    /// the policy moves afterwards.
    func handleSettingsWillClose() {
        guard isPresenting else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        isPresenting = false
        if let startingPolicy {
            deps.setPolicy(startingPolicy)
        }
        for delay in Self.settleChecks {
            deps.asyncAfter(delay) { [weak self] in self?.settle() }
        }
    }

    /// The framework changes the activation policy around the close of the
    /// app's last window on its own. Measured on macOS 27 (2026-11-24): the
    /// policy read `.accessory` when the close was handled and `.regular`
    /// again right after, with no call from this app in between, and the
    /// Dock icon stayed. The one write above is not trusted on its own: the
    /// policy is read again and put back if it moved.
    private func settle() {
        guard !isPresenting, let startingPolicy, deps.policy() != startingPolicy else { return }
        deps.setPolicy(startingPolicy)
    }
}
