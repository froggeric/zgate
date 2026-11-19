import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Tab model (tested derivations)

/// Tested logic for the Splash tab (state line, button states, persistence).
/// The pure statics are `nonisolated` (codebase idiom under default
/// MainActor isolation) so the test target binds them without hops.
@MainActor
@Observable
final class SplashTabModel {
    let manager: SplashManager
    var profiles: [SplashProfile]
    var activeProfileID: UUID?
    var keepRunning: Bool
    var binaryPathOverride: String?
    var port: Int
    /// Machine-level storage settings carried through save round-trips
    /// until the Storage UI (spec §3.6) gains real fields — dropping them
    /// here would silently lose the flags migration 8 lifted.
    var storage: SplashStorage?
    static let portRange = 1024...65535
    private let persist: @MainActor (SplashSettings) -> Void

    init(
        manager: SplashManager, settings: SplashSettings?,
        persist: @escaping @MainActor (SplashSettings) -> Void
    ) {
        self.manager = manager
        let s = settings ?? SplashSettings()
        self.profiles = s.profiles
        self.activeProfileID = s.activeProfileID
        self.keepRunning = s.keepRunning
        self.binaryPathOverride = s.binaryPathOverride
        self.port = s.port
        self.storage = s.storage
        self.persist = persist
    }

    func settings() -> SplashSettings {
        SplashSettings(
            keepRunning: keepRunning, activeProfileID: activeProfileID,
            profiles: profiles, binaryPathOverride: binaryPathOverride, port: port,
            storage: storage)
    }

    /// Ports outside the valid range don't apply — the view disables
    /// submission and keeps serving the last valid configuration.
    var portIsValid: Bool { Self.portRange.contains(port) }


    /// Persist; when we're supposed to run, restart onto the active profile
    /// (spec §4: switching = restart; stopped → just record). The manager's
    /// settings are refreshed FIRST so its supervision guards (adopted
    /// takeover, backoff relaunch) never act on a stale keepRunning.
    /// Toggle-OFF stops the owned child from the VIEW (`manager.canStop`,
    /// spec §4) — saveAndApply itself never signals children.
    func saveAndApply() async {
        guard portIsValid else { return }   // mid-edit ports never persist, rebind, or restart
        let s = settings()
        persist(s)
        manager.applySettings(s)
        // Restart covers port changes too: --port is baked into the
        // running server's argv, so a new port must rebind.
        if keepRunning, let p = s.activeProfile {
            await manager.restart(profile: p)
        }
    }

    /// Spec §5.2: remove a profile; deleting the ACTIVE one also clears
    /// `activeProfileID` (the nil-active paths then disable Start). Deleting
    /// the last profile is allowed. Persisting is the caller's saveAndApply.
    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
    }

    /// Brew execution seam for the M3+ install branch (spec §5.3). argv is
    /// the FULL command (`SplashInstaller.brewArguments` — argv[0] is the
    /// executable). Tests inject a recording closure; no test ever runs
    /// brew or spawns a Process. Default delegates to the installer's
    /// process seam (`SplashInstaller.runBrew`).
    var runBrew: @Sendable ([String]) async throws -> Void = { argv in
        try await SplashInstaller.runBrew(argv: argv)
    }

    // MARK: Pure derivations (tested)

    nonisolated static func duration(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    /// Adopted instances show `external` instead of an uptime we don't own.
    nonisolated static func stateLine(_ state: SplashState, now: Date) -> String {
        switch state {
        case .stopped: return "stopped"
        case .stopping: return "stopping…"
        case .starting(let p): return "starting · \(p)"
        case .running(let p, _, true): return "running · \(p) · external"
        case .running(let p, let since, false):
            return "running · \(p) · \(duration(now.timeIntervalSince(since)))"
        case .crashed(_, let lastExit, let nextRetry):
            var s = "crashed · exit \(lastExit)"
            if let next = nextRetry { s += " · retry in \(max(0, Int(next.timeIntervalSince(now)))) s" }
            return s
        }
    }

    /// Stop/restart are offered only for an OWNED child (spec §3.1: adopted
    /// and external instances are never ours to signal).
    nonisolated static func buttonStates(_ state: SplashState) -> (start: Bool, stop: Bool, restart: Bool) {
        switch state {
        case .stopped: return (true, false, false)
        case .stopping, .starting: return (false, false, false)
        case .running(_, _, let adopted):
            return (false, !adopted, true)
        case .crashed: return (true, false, true)
        }
    }

    nonisolated static func installLine(chip: String, variant: String, installed: String?, latest: String?) -> String {
        var s = "\(chip) · \(variant)"
        if let installed { s += " \(installed) installed" } else { s += " · not installed" }
        if let latest { s += " · \(latest) available" }
        return s
    }

    /// Spec §5.3 install branch: fork binary on M1/M2, official Homebrew
    /// formula on M3+. Unknown chips stay on fork so the install row's
    /// variant text (derived from the same call) and the branch actually
    /// taken can never disagree.
    nonisolated static func installVariant(chipKind: SplashChip?) -> SplashInstallVariant {
        chipKind == .officialM3Plus ? .brewOfficial : .fork
    }
}

/// Which binary `runInstall` fetches on this machine (spec §5.3).
enum SplashInstallVariant: Equatable, Sendable {
    case fork, brewOfficial
}

extension SplashProfile {
    /// One TextField, whitespace-split (paths in the owner's setup have no
    /// spaces; documented limitation in the editor's help text).
    nonisolated static func parseExtraArgs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

// MARK: - Splash tab (spec §5)

struct SplashTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(SplashManager.self) private var manager
    @State private var model: SplashTabModel?
    @State private var editingProfile: SplashProfile?
    @State private var discovered: [SplashModelInfo] = []
    @State private var installLine: String = "…"
    @State private var installBusy = false
    @State private var chipKind: SplashChip?   // cached for runInstall's branch
    @State private var deletingProfile: SplashProfile?

    var body: some View {
        Form {
            statusSection
            profilesSection
            installSection
            logSection
        }
        .formStyle(.grouped)
        .padding()
        .task {
            if model == nil {
                model = SplashTabModel(manager: manager, settings: configStore.config.splash) { cfg in
                    configStore.config.splash = cfg
                    configStore.save()
                }
            }
            discovered = await SplashModelsClient().models(baseURL: SplashModelsClient.endpoint(port: model?.settings().port ?? 8123))
            refreshInstallLine()
        }
        .sheet(item: $editingProfile) { profile in
            SplashProfileEditorView(profile: profile, discovered: discovered) { saved in
                if let m = model {
                    if let i = m.profiles.firstIndex(where: { $0.id == saved.id }) {
                        m.profiles[i] = saved
                    } else {
                        m.profiles.append(saved)   // "Add profile…" round-trip
                    }
                    // Persist WITHOUT applying: an editor save must not
                    // restart the server (saveAndApply would) — same
                    // non-restarting persist as the model's own closure.
                    configStore.config.splash = m.settings()
                    configStore.save()
                }
                editingProfile = nil
            }
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let m = model, let profile = deletingProfile {
                    m.deleteProfile(id: profile.id)   // clears active if it was p (§5.2)
                    Task { await m.saveAndApply() }
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: {
            if let profile = deletingProfile, let m = model {
                if m.activeProfileID == profile.id {
                    Text("Deleting the active profile also clears the active selection — splash won't start until you pick another.")
                } else {
                    Text("Remove \"\(profile.name)\"? This cannot be undone.")
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Server") {
            if let m = model {
                HStack(spacing: 6) {
                    // Same shape language as the popover's splash chip
                    // (filled / half / dashed / alert) — state survives
                    // color-blind viewing and both appearances.
                    Image(systemName: statusSymbol)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                    Text(SplashTabModel.stateLine(manager.state, now: Date()))
                        .font(.callout)
                    Spacer()
                }
                HStack {
                    Button("Start") {
                        Task { if let p = m.settings().activeProfile { await manager.start(profile: p) } }
                    }
                    .disabled(!SplashTabModel.buttonStates(manager.state).start)
                    Button("Stop") { Task { await manager.stop() } }
                        .disabled(!manager.canStop)
                    Button("Restart") {
                        Task { if let p = m.settings().activeProfile { await manager.restart(profile: p) } }
                    }
                    .disabled(!SplashTabModel.buttonStates(manager.state).restart)
                }
                // Off → persist first, then stop ONLY our own child (spec §4;
                // adopted/external instances are never ours to signal).
                Toggle("Keep splash running", isOn: Binding(
                    get: { m.keepRunning },
                    set: { on in
                        m.keepRunning = on
                        Task {
                            await m.saveAndApply()
                            if !on && manager.canStop { await manager.stop() }
                        }
                    }))
                HStack {
                    Text("Port")
                    Spacer()
                    TextField(
                        "Port", text: Binding(
                            get: { String(m.port) },
                            set: { text in
                                guard let p = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
                                m.port = p
                                // Apply only VALID ports: mid-typing ("8",
                                // "81", "812") must never persist or rebind.
                                if m.portIsValid {
                                    Task { await m.saveAndApply() }
                                }
                            }))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .foregroundStyle(m.portIsValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                }
                if !m.portIsValid {
                    Text("Port must be 1024–65535; changes apply (and restart the server) once valid.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var statusSymbol: String {
        SplashLifecycleChip.face(for: manager.state, now: Date()).symbolName
    }

    private var statusColor: Color {
        switch manager.state {
        case .running: return .green
        case .crashed: return .orange
        case .starting, .stopping: return .secondary
        case .stopped: return .secondary
        }
    }

    private var profilesSection: some View {
        Section("Model profiles") {
            if let m = model {
                Picker("Active", selection: Binding(
                    get: { m.activeProfileID ?? UUID() },
                    set: { m.activeProfileID = $0; Task { await m.saveAndApply() } })) {
                    ForEach(m.profiles) { p in Text(p.name).tag(p.id) }
                }
                ForEach(m.profiles) { p in
                    HStack {
                        Text(p.name).font(.callout)
                        Spacer()
                        Text(p.model).font(.callout).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingProfile = p }
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            deletingProfile = p
                        }
                    }
                }
                Button("Add profile…") {
                    editingProfile = SplashProfile(name: "New profile", model: "")
                }
            }
        }
    }

    private var installSection: some View {
        Section("Binary") {
            HStack {
                Text(installLine).font(.callout)
                Spacer()
                Button(installBusy ? "Installing…" : "Update / Install") {
                    Task { await runInstall() }
                }
                .disabled(installBusy)
            }
        }
    }

    private var logSection: some View {
        Section("Log") { SplashLogTail(lines: manager.log.lines) }
    }

    private func refreshInstallLine() {
        Task {
            let brand = SplashChip.currentBrandString() ?? "Unknown chip"
            chipKind = SplashChip.from(brandString: brand)
            // Same derivation runInstall branches on — label and action agree.
            let variant = SplashTabModel.installVariant(chipKind: chipKind) == .brewOfficial
                ? "official" : "fork"
            let binary = SplashManager.resolvedBinaryPath(override: model?.binaryPathOverride)
            let installed = await SplashInstaller.installedVersion(binaryPath: binary)
                .flatMap(Self.versionToken)
            let latest = await SplashInstaller().latestRelease(for: chipKind)?.tag_name
            installLine = SplashTabModel.installLine(
                chip: brand, variant: variant, installed: installed, latest: latest)
        }
    }

    /// `Splash 1.6.1-m1` (or a bare version token) → `1.6.1-m1` for the
    /// install row; keeps the fork suffix `SplashVersion.parse` drops.
    nonisolated private static func versionToken(_ output: String) -> String? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard let idx = tokens.firstIndex(of: "Splash"), idx + 1 < tokens.count else {
            return tokens.first.map(String.init)
        }
        return String(tokens[idx + 1])
    }

    private func runInstall() async {
        installBusy = true
        defer { installBusy = false }
        // Chip-gated branch (spec §5.3): fork binary on M1/M2, official
        // Homebrew formula on M3+ — same variant the install row shows.
        switch SplashTabModel.installVariant(chipKind: chipKind) {
        case .fork:
            guard let release = await SplashInstaller().latestRelease(for: chipKind) else {
                installLine += " · no release info"
                return
            }
            do {
                _ = try await SplashTarballInstaller().install(release: release)
                refreshInstallLine()
            } catch {
                installLine += " · install failed"
            }
        case .brewOfficial:
            guard let m = model else { return }
            // Same probe the install row's "installed" text uses, so the
            // install/upgrade verb matches what the row claims.
            let binary = SplashManager.resolvedBinaryPath(override: m.binaryPathOverride)
            let installed = await SplashInstaller.installedVersion(binaryPath: binary) != nil
            do {
                try await m.runBrew(SplashInstaller.brewArguments(installed: installed))
                refreshInstallLine()
            } catch {
                installLine += " · install failed"   // identical handling to fork
            }
        }
    }
}

// MARK: - Profile editor sheet

/// Profile editor sheet: discovery dropdown + free text, flag fields,
/// extraArgs as one whitespace-split line. Plain VStack + footer (the
/// RuleEditorSheet arrangement), not a hypothetical `Sheet/footer` API.
struct SplashProfileEditorView: View {
    @State var profile: SplashProfile
    let discovered: [SplashModelInfo]
    let onSave: (SplashProfile) -> Void
    @State private var extraArgsRaw: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $profile.name)
                HStack {
                    TextField("Model (--model)", text: $profile.model)
                    if !discovered.isEmpty {
                        Menu("Serving") {
                            ForEach(discovered) { d in
                                Button(d.id) { profile.model = d.id }
                            }
                        }
                        .fixedSize()
                    }
                }
                TextField("Model dir (--model-dir)", text: optionalBinding($profile.modelDir))
                TextField("Draft model (--draft-model)", text: optionalBinding($profile.draftModel))
                TextField("mmproj (--mmproj)", text: optionalBinding($profile.mmproj))
                TextField("Extra args", text: $extraArgsRaw)
                    .help("Whitespace-separated, appended verbatim after the flags above")
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    profile.extraArgs = SplashProfile.parseExtraArgs(extraArgsRaw)
                    onSave(profile)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.isEmpty || profile.model.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { extraArgsRaw = profile.extraArgs.joined(separator: " ") }
    }

    /// Empty text ⇄ nil (omitted flag).
    private func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Log tail

/// Monospaced auto-scrolling tail of the manager's ring buffer.
struct SplashLogTail: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.subheadline.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 160, maxHeight: 300)
            .onAppear {
                if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
            // Key on the newest line, not the count: the ring holds the
            // count constant at capacity, where a count-keyed follow would
            // permanently stop tracking new output.
            .onChange(of: lines.last) { _, _ in
                if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .contextMenu {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }
}
