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
        self.persist = persist
    }

    func settings() -> SplashSettings {
        SplashSettings(
            keepRunning: keepRunning, activeProfileID: activeProfileID,
            profiles: profiles, binaryPathOverride: binaryPathOverride)
    }

    /// Persist; when we're supposed to run, restart onto the active profile
    /// (spec §4: switching = restart; stopped → just record). Toggle-OFF
    /// stops the owned child from the VIEW (`manager.canStop`, spec §4) —
    /// saveAndApply itself never stops.
    func saveAndApply() async {
        persist(settings())
        if keepRunning, let p = settings().activeProfile {
            await manager.restart(profile: p)
        }
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
            if let next = nextRetry { s += " · retry in \(Int(next.timeIntervalSince(now))) s" }
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
            discovered = await SplashModelsClient().models()
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
                }
                editingProfile = nil
            }
        }
    }

    private var statusSection: some View {
        Section("Server") {
            if let m = model {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(SplashTabModel.stateLine(manager.state, now: Date()))
                        .font(.footnote)
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
            }
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .running: return .green
        case .crashed: return .orange
        case .starting, .stopping: return .gray
        case .stopped: return Color.secondary.opacity(0.5)
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
                        Text(p.name).font(.footnote)
                        Spacer()
                        Text(p.model).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingProfile = p }
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
                Text(installLine).font(.caption)
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
            let chipKind = SplashChip.from(brandString: brand)
            let variant = chipKind == .officialM3Plus ? "official" : "fork"
            let binary = SplashManager.resolvedBinaryPath(override: model?.binaryPathOverride)
            let installed = await SplashInstaller.installedVersion(binaryPath: binary)
                .flatMap(Self.versionToken)
            let latest = await SplashInstaller().latestForkRelease()?.tag_name
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
        guard let release = await SplashInstaller().latestForkRelease(),
              let asset = SplashAssetPicker.binaryURL(from: release) else {
            installLine += " · no unambiguous binary asset"
            return
        }
        do {
            let outcome = try await SplashInstaller().installForkBinary(from: release)
            if case .installedAt(let path, let fallback) = outcome, fallback,
               let m = model {
                m.binaryPathOverride = path
                await m.saveAndApply()
            }
            _ = asset   // selection is re-derived inside installForkBinary
            refreshInstallLine()
        } catch {
            installLine += " · install failed"
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
                Spacer()
                Button("Save") {
                    profile.extraArgs = SplashProfile.parseExtraArgs(extraArgsRaw)
                    onSave(profile)
                }
                .buttonStyle(.borderedProminent)
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
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 140, maxHeight: 260)
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
