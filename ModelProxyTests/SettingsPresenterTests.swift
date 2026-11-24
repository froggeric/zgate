import AppKit
import Testing
@testable import ZGate

/// `SettingsPresenter` through its seams (2026-11-23). What it must do, and
/// why: a menu-bar app holds the foreground only while it presents as a
/// regular app, so the presenter must switch the policy — and must give it
/// back exactly once when Settings closes. A missed restore leaves a Dock
/// icon behind for the rest of the session; an early one drops Settings
/// behind every other window again.
@MainActor
@Suite struct SettingsPresenterTests {

    /// Records instead of touching the screen: a never-shown window whose
    /// `makeKeyAndOrderFront` would otherwise show it.
    private final class SpyWindow: NSWindow {
        var raised = 0
        override func makeKeyAndOrderFront(_ sender: Any?) {
            raised += 1
        }
    }

    private final class Journal {
        var calls: [String] = []
        var policies: [NSApplication.ActivationPolicy] = []
    }

    /// Scripted answers for "which windows exist right now": one array per
    /// lookup, then the last one repeats.
    private final class WindowSource {
        var answers: [[NSWindow]] = []
        func next() -> [NSWindow] {
            answers.count > 1 ? answers.removeFirst() : (answers.first ?? [])
        }
    }

    private func settingsWindow() -> SpyWindow {
        let window = SpyWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(SettingsPresenter.settingsWindowID)
        return window
    }

    private func makePresenter(
        journal: Journal,
        source: WindowSource,
        startingPolicy: NSApplication.ActivationPolicy = .accessory
    ) -> SettingsPresenter {
        SettingsPresenter(deps: SettingsPresenter.Deps(
            policy: { startingPolicy },
            setPolicy: { policy in
                journal.policies.append(policy)
                journal.calls.append("policy \(policy.rawValue)")
            },
            activate: { journal.calls.append("activate") },
            windows: { source.next() },
            async: { work in work() },
            asyncAfter: { _, work in work() }))
    }

    private func present(_ presenter: SettingsPresenter, journal: Journal) {
        presenter.present(
            dismiss: { journal.calls.append("dismiss") },
            open: { journal.calls.append("open") })
    }

    // MARK: - Lookup

    @Test func settingsWindowIsFoundByTheSwiftUISceneIdentifier() {
        let other = SpyWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.identifier = NSUserInterfaceItemIdentifier("something-else")
        let settings = settingsWindow()
        #expect(SettingsPresenter.settingsWindow(in: [other]) == nil)
        #expect(SettingsPresenter.settingsWindow(in: [other, settings]) === settings)
    }

    // MARK: - Present

    /// The panel MUST be dismissed through the caller's own action, before
    /// anything else: closing it any other way leaves MenuBarExtra's state
    /// stale and swallows the user's next menu-bar click.
    @Test func presentDismissesThePanelFirstThenSwitchesPolicyOpensActivatesAndRaises() {
        let journal = Journal()
        let source = WindowSource()
        let settings = settingsWindow()
        source.answers = [[settings]]
        let presenter = makePresenter(journal: journal, source: source)

        present(presenter, journal: journal)

        #expect(journal.calls == ["dismiss", "policy 0", "open", "activate"])  // 0 = .regular
        #expect(settings.raised == 1)
        #expect(presenter.isPresenting)
    }

    @Test func closingSettingsRestoresTheStartingPolicyExactlyOnce() {
        let journal = Journal()
        let source = WindowSource()
        source.answers = [[settingsWindow()]]
        let presenter = makePresenter(journal: journal, source: source, startingPolicy: .prohibited)
        present(presenter, journal: journal)

        presenter.handleSettingsWillClose()
        #expect(journal.policies == [.regular, .prohibited])  // what it started from, not a hard-coded value
        #expect(!presenter.isPresenting)

        presenter.handleSettingsWillClose()  // a stale notification must not restore twice
        #expect(journal.policies == [.regular, .prohibited])
    }

    @Test func presentingTwiceKeepsTheOriginalPolicyToRestore() {
        let journal = Journal()
        let source = WindowSource()
        source.answers = [[settingsWindow()], [settingsWindow()]]
        let presenter = makePresenter(journal: journal, source: source)
        present(presenter, journal: journal)
        present(presenter, journal: journal)  // Settings already open; raised again

        #expect(journal.policies == [.regular, .regular])
        presenter.handleSettingsWillClose()
        #expect(journal.policies == [.regular, .regular, .accessory])
    }

    // MARK: - The window that never comes

    @Test func aSettingsWindowThatNeverAppearsGivesThePolicyBack() {
        let journal = Journal()
        let source = WindowSource()
        source.answers = [[]]
        let presenter = makePresenter(journal: journal, source: source)

        present(presenter, journal: journal)

        #expect(journal.policies == [.regular, .accessory])
        #expect(!presenter.isPresenting)
    }

    @Test func aLateSettingsWindowIsStillRaisedAndHeld() {
        let journal = Journal()
        let source = WindowSource()
        let settings = settingsWindow()
        source.answers = [[], [], [settings]]
        let presenter = makePresenter(journal: journal, source: source)

        present(presenter, journal: journal)

        #expect(settings.raised == 1)
        #expect(journal.policies == [.regular])
        #expect(presenter.isPresenting)
    }

    // MARK: - The framework's own change at the close

    /// A presenter whose clock moves only when the test says so, over a policy
    /// the test can also change from outside — as the framework does.
    @MainActor private final class Rig {
        let journal = Journal()
        var policy: NSApplication.ActivationPolicy = .accessory
        var deferred: [@MainActor () -> Void] = []
        let source = WindowSource()
        lazy var presenter: SettingsPresenter = SettingsPresenter(deps: SettingsPresenter.Deps(
            policy: { self.policy },
            setPolicy: { self.policy = $0; self.journal.policies.append($0) },
            activate: {},
            windows: { self.source.next() },
            async: { work in work() },
            asyncAfter: { _, work in self.deferred.append(work) }))

        func runDeferred() {
            let works = deferred
            deferred = []
            works.forEach { $0() }
        }
    }

    /// Found on the release build (2026-11-24): the policy read `.accessory`
    /// when the close was handled and `.regular` again right after, with no
    /// call from this app in between. The Dock icon stayed. A single write at
    /// the close can land between the framework's two changes.
    @Test func aPolicyChangedAfterTheCloseIsPutBack() {
        let rig = Rig()
        rig.source.answers = [[settingsWindow()]]
        present(rig.presenter, journal: rig.journal)

        rig.presenter.handleSettingsWillClose()
        #expect(rig.journal.policies == [.regular, .accessory])

        rig.policy = .regular  // the framework's change, after the restore
        rig.runDeferred()

        #expect(rig.journal.policies == [.regular, .accessory, .accessory])
    }

    /// A check that comes due after Settings was opened again must leave the
    /// policy alone: Settings needs the regular policy while it is open.
    @Test func aCheckAfterTheCloseLeavesSettingsAloneWhenItIsOpenAgain() {
        let rig = Rig()
        rig.source.answers = [[settingsWindow()], [settingsWindow()]]
        present(rig.presenter, journal: rig.journal)
        rig.presenter.handleSettingsWillClose()
        let deferred = rig.deferred
        rig.deferred = []

        present(rig.presenter, journal: rig.journal)  // opened again before the checks
        #expect(rig.policy == .regular)
        deferred.forEach { $0() }

        #expect(rig.journal.policies == [.regular, .accessory, .regular])
        #expect(rig.policy == .regular)
        #expect(rig.presenter.isPresenting)
    }
}
