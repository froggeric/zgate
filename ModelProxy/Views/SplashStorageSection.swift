import AppKit
import Foundation
import SwiftUI

/// Storage & cache settings (spec §3.6/§5) — machine-level rows living in
/// the Splash tab between Profiles and Binary. Every edit persists via
/// `SplashTabModel.persistOnly()` (non-restarting, like the profile
/// editor): flags and `HF_HUB_CACHE` land at the next start, so a hint
/// says so while an owned server is running. Destructive actions confirm;
/// "Delete old location" after a move is a separate explicit action.
struct SplashStorageSection: View {
    let model: SplashTabModel
    /// Tests inject fixtures through the client's fetch seam; production
    /// hits the live server.
    private let client = SplashStatusClient()
    private let actions = StorageActions()

    @State private var cacheSizeKB: Int?
    @State private var volumeFree: Int64?
    @State private var diskStatus: SplashDiskStatus?
    @State private var moving = false
    @State private var actionError: String?
    @State private var moveBackup: URL?
    @State private var quotaCustom = ""
    @State private var writeBudgetRaw = ""
    @State private var confirmingClearCache = false
    @State private var confirmingClearPrefix = false
    @State private var confirmingDeleteBackup = false

    var body: some View {
        Group {
            modelCacheRows
            prefixCacheRows
            Text("Profile extraArgs may override these.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task(id: effectiveModelCache.path) { await refreshStats() }
        // Re-poll while running; stop (and hide) otherwise. Keyed on
        // running-state + port so a restart or port change re-seeds it.
        .task(id: "\(isRunning)-\(model.port)") { await pollUsage() }
        .onAppear { seedFields() }
        .confirmationDialog(
            "Clear model cache?", isPresented: $confirmingClearCache, titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clearModelCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the downloaded models in \(effectiveModelCache.path). They re-download on the next serve.")
        }
        .confirmationDialog(
            "Clear prefix cache?", isPresented: $confirmingClearPrefix, titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clearPrefixCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes splash's prefix caches in \(effectivePrefixRoot?.path ?? "the cache dir"). They rebuild on demand.")
        }
        .confirmationDialog(
            "Delete old cache location?", isPresented: $confirmingDeleteBackup, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteBackup() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Permanently deletes \(moveBackup?.path ?? "the old location"). This cannot be undone.")
        }
    }

    // MARK: Model cache (HF downloads)

    private var modelCacheRows: some View {
        Group {
            LabeledContent("Model cache") {
                Text(modelCacheDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(effectiveModelCache.path)
            }
            LabeledContent("On disk") {
                Text(cacheSizeKB.map(Self.kbString) ?? "…")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Volume free") {
                Text(volumeFree.map(Self.byteString) ?? "…")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Change…") { changeModelCache() }
                Button(moving ? "Moving…" : "Move…") { runMove() }
                    .disabled(!isStopped || moving)
                Button("Reveal") { revealModelCache() }
                    .disabled(!FileManager.default.fileExists(atPath: effectiveModelCache.path))
                Button("Clear…") { confirmingClearCache = true }
                    .disabled(!isStopped || moving)   // never clear mid-move
            }
            if moving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Copying the cache — verify runs before anything is renamed…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let backup = moveBackup {
                HStack {
                    Text("Old location kept: \(backup.lastPathComponent)")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(backup.path)
                    Spacer()
                    Button("Delete old location…") { confirmingDeleteBackup = true }
                }
            }
            if !isStopped {
                Text("Stop splash before moving or clearing caches.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if case .running(_, _, false) = model.manager.state {
                Text("Storage changes apply at the next start — restart splash to use them now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let actionError {
                Text(actionError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: Prefix cache (--persistent-cache / --cache-dir)

    private var prefixCacheRows: some View {
        Group {
            Toggle("Persistent prefix cache", isOn: Binding(
                get: { model.storage?.persistentCache ?? false },
                set: { on in setStorage { $0.persistentCache = on } }))
            LabeledContent("Prefix cache dir") {
                HStack {
                    Text(prefixDirDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { choosePrefixDir() }
                        .disabled(!(model.storage?.persistentCache ?? false))
                }
            }
            // Without --persistent-cache splash ignores --cache-dir (spec §2)
            // — hence the gated dir picker. The quota itself still emits
            // (launchFlags sends --max-cache-disk regardless), so it stays
            // enabled and truthful to what ZGate will pass.
            Picker("Disk quota", selection: quotaBinding) {
                Text("Auto").tag(QuotaMode.auto)
                Text("Off").tag(QuotaMode.off)
                Text("Custom").tag(QuotaMode.custom)
            }
            if quotaMode == .custom {
                sizeField(
                    label: "Quota size", placeholder: "16G",
                    raw: $quotaCustom,
                    apply: { v in setStorage { $0.maxCacheDisk = v } })
            }
            sizeField(
                label: "Write budget", placeholder: "200G",
                raw: $writeBudgetRaw,
                apply: { v in setStorage { $0.maxCacheDiskWrites = v } })
            if isRunning, let line = diskStatus.map(Self.usageLine), !line.isEmpty {
                LabeledContent("Prefix usage") {
                    Text(line).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Clear prefix cache…") { confirmingClearPrefix = true }
                    .disabled(!isStopped || effectivePrefixRoot == nil)
                if effectivePrefixRoot == nil {
                    Text("Needs a persistent cache dir")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Quota mode plumbing

    private enum QuotaMode: String, CaseIterable, Identifiable {
        case auto, off, custom
        var id: String { rawValue }
    }

    /// nil → Auto, "0" → Off (spec §2 quota semantics), anything else →
    /// Custom carrying that value in the size field.
    private var quotaMode: QuotaMode {
        switch model.storage?.maxCacheDisk {
        case nil, "": return .auto
        case "0": return .off
        default: return .custom
        }
    }

    private var quotaBinding: Binding<QuotaMode> {
        Binding(
            get: { quotaMode },
            set: { mode in
                switch mode {
                case .auto:
                    setStorage { $0.maxCacheDisk = nil }
                case .off:
                    setStorage { $0.maxCacheDisk = "0" }
                case .custom:
                    // Persist a valid starter so the picker STAYS on Custom
                    // (an empty custom value would read back as Auto).
                    setStorage { s in
                        if s.maxCacheDisk == nil || s.maxCacheDisk == "0" { s.maxCacheDisk = "16G" }
                    }
                    quotaCustom = model.storage?.maxCacheDisk ?? "16G"
                }
            })
    }

    /// One validated size field (quota custom + write budget share it):
    /// empty → flag omitted; invalid text stays red and never persists
    /// (the port field's mid-edit discipline).
    private func sizeField(
        label: String, placeholder: String,
        raw: Binding<String>,
        apply: @escaping (String?) -> Void
    ) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: Binding(
                get: { raw.wrappedValue },
                set: { text in
                    raw.wrappedValue = text
                    let t = text.trimmingCharacters(in: .whitespaces)
                    apply(t.isEmpty ? nil : (Self.isValidSizeSpec(t) ? t : nil))
                }))
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
            .foregroundStyle(Self.fieldStyleState(raw: raw.wrappedValue))
            .help("Format: a number with K, M or G — e.g. 16G, 512M, 1.5G")
        }
    }

    // MARK: Derived values

    /// `modelCacheLocation` when set, else splash's HF default (spec §2).
    private var effectiveModelCache: URL {
        if let loc = model.storage?.modelCacheLocation, !loc.isEmpty {
            return URL(fileURLWithPath: loc, isDirectory: true)
        }
        return StorageActions.defaultHFCache
    }

    private var modelCacheDisplay: String {
        if let loc = model.storage?.modelCacheLocation, !loc.isEmpty { return loc }
        return "Default (\(StorageActions.defaultHFCache.path))"
    }

    /// The dir Clear-prefix-cache wipes: only exists with persistent cache
    /// on (without it the cache lives in $TMPDIR and ignores --cache-dir).
    private var effectivePrefixRoot: URL? {
        guard model.storage?.persistentCache == true else { return nil }
        if let d = model.storage?.cacheDir, !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return StorageActions.defaultPrefixCache
    }

    private var prefixDirDisplay: String {
        if let d = model.storage?.cacheDir, !d.isEmpty { return d }
        return StorageActions.defaultPrefixCache.path + " (default)"
    }

    /// Clear/move act on live files: strictly `.stopped` (a crashed state
    /// means a supervised relaunch is pending).
    private var isStopped: Bool { model.manager.state == .stopped }

    private var isRunning: Bool {
        if case .running = model.manager.state { return true }
        return false
    }

    // MARK: Actions

    /// Mutate one storage field and persist WITHOUT restarting (Task 9's
    /// non-applying persist; the manager's snapshot converges on the next
    /// saveAndApply or restart).
    private func setStorage(_ mutate: (inout SplashStorage) -> Void) {
        var s = model.storage ?? SplashStorage()
        mutate(&s)
        model.storage = s
        model.persistOnly()
    }

    private func seedFields() {
        quotaCustom = model.storage?.maxCacheDisk ?? ""
        writeBudgetRaw = model.storage?.maxCacheDiskWrites ?? ""
    }

    private func pickDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = title
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func changeModelCache() {
        guard let url = pickDirectory(title: "Model cache location") else { return }
        setStorage { $0.modelCacheLocation = url.path }
    }

    private func choosePrefixDir() {
        guard let url = pickDirectory(title: "Prefix cache directory") else { return }
        setStorage { $0.cacheDir = url.path }
    }

    /// Move… (spec §3.6): stopped-only; ditto → du verify → source renamed
    /// to a `.zgate-moved-<ts>` backup the user may delete explicitly.
    private func runMove() {
        guard !moving else { return }
        let source = effectiveModelCache
        guard let parent = pickDirectory(title: "Move the model cache into…") else { return }
        let target = parent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        moving = true
        actionError = nil
        Task {
            defer { moving = false }
            do {
                let backup = try await actions.moveModelCache(from: source, to: target)
                setStorage { $0.modelCacheLocation = target.path }
                moveBackup = backup
                await refreshStats()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deleteBackup() {
        guard let backup = moveBackup else { return }
        try? FileManager.default.removeItem(at: backup)
        moveBackup = nil
    }

    private func revealModelCache() {
        NSApp.activate()   // NSWorkspace.activate is deprecated since macOS 14
        NSWorkspace.shared.open(effectiveModelCache)
    }

    /// Destructive-confirm clear of the model cache: remove the CONTENTS
    /// (spec §3.6 — models re-download on next serve), keep the dir itself.
    private func clearModelCache() {
        let fm = FileManager.default
        let dir = effectiveModelCache
        guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for c in children { try? fm.removeItem(at: dir.appendingPathComponent(c)) }
        Task { await refreshStats() }
    }

    private func clearPrefixCache() {
        guard let root = effectivePrefixRoot else { return }
        do {
            try StorageActions.clearPrefixCache(root: root)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Stats & live usage

    private func refreshStats() async {
        let url = effectiveModelCache
        cacheSizeKB = await Self.duKB(of: url)
        volumeFree = Self.volumeFree(for: url)
    }

    private func pollUsage() async {
        guard isRunning else {
            diskStatus = nil
            return
        }
        let port = model.port
        while !Task.isCancelled && isRunning {
            diskStatus = await client.diskStatus(port: port)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: Pure helpers (nonisolated: testable, no MainActor hop)

    /// `^\d+(\.\d+)?[KMG]$` (spec §5): whole-string match, K/M/G only.
    nonisolated static func isValidSizeSpec(_ s: String) -> Bool {
        guard let r = try? Regex("^\\d+(\\.\\d+)?[KMG]$") else { return false }
        return s.trimmingCharacters(in: .whitespaces).wholeMatch(of: r) != nil
    }

    nonisolated private static func kbString(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file)
    }

    nonisolated private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Live usage line from /status's disk object — only what splash
    /// actually reported; `writes gated` surfaced when it isn't "no".
    nonisolated static func usageLine(_ d: SplashDiskStatus) -> String {
        var parts: [String] = []
        if let used = d.usedBytes {
            parts.append(d.limitBytes.map { "\(byteString(Int64(used))) used of \(byteString(Int64($0)))" }
                ?? "\(byteString(Int64(used))) used")
        }
        if let free = d.volumeAvailableBytes { parts.append("\(byteString(Int64(free))) volume free") }
        if let gated = d.writesGated, gated != "no" { parts.append("writes gated: \(gated)") }
        return parts.joined(separator: " · ")
    }

    /// Red only for non-empty, invalid text; valid or empty renders primary.
    nonisolated private static func fieldStyleState(raw: String) -> AnyShapeStyle {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return AnyShapeStyle(.primary) }
        return isValidSizeSpec(t) ? AnyShapeStyle(.primary) : AnyShapeStyle(.red)
    }

    /// `du -sk` (1 KB blocks) of a path — nil when the path is gone; runs
    /// through StorageActions' detached process seam, never the main actor.
    nonisolated private static func duKB(of url: URL) async -> Int? {
        guard let out = try? await StorageActions().capture(["/usr/bin/du", "-sk", url.path]),
              let kb = Int(out.split(separator: "\t").first ?? "") else { return nil }
        return kb
    }

    /// Free space of the volume holding `url`, walking up to the nearest
    /// EXISTING ancestor (the configured dir may not exist yet).
    nonisolated private static func volumeFree(for url: URL) -> Int64? {
        let fm = FileManager.default
        var probe = url
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return free
    }
}
