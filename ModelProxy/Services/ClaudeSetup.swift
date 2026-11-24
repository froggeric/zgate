import CryptoKit
import Foundation

// The Claude Code settings configurator (spec v2, 2026-11-23): what to
// recommend, which keys that changes, and the one place that writes the file.
//
// Measured on Claude Code 2.1.323 against a local stub — the numbers the
// configurator relies on:
// - an id Claude Code does not know gets a 1M window, unless
//   `CLAUDE_CODE_MAX_CONTEXT_TOKENS` says less. `[1m]` pins it to 1M whatever
//   that variable says — a session keeps the environment it started with;
// - with `[1m]` the proactive check runs only once a window is set for the id
//   (`modelSettings.<id>.autoCompactWindow`); without one it is skipped;
// - `modelSettings.<id>.autoCompactWindow` sets the id's window (100000 or more);
// - the effective window is the window less 20,000; compaction runs at
//   `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` percent of it (96.7% without the variable).

// MARK: - Recommendation

/// Where ZGate routes an id Claude Code asks for: enough to size its window.
struct ClaudeSetupTarget: Equatable, Sendable {
    var model: String?
    /// A model on the local splash server, whose `/v1/models` reports a context length.
    var isSplash: Bool
    /// The vendor's name, for display.
    var vendor: String? = nil
}

/// What the configurator recommends for Claude Code's settings file.
struct ClaudeSetupRecommendation: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// Set in ZGate for this role.
            case setHere
            /// Read from splash for the routed model.
            case splash
            /// ZGate's default window for a model it knows no window for.
            case defaultWindow
        }

        var tokens: Int
        var source: Source

        /// The token count Claude Code compacts at: the percentage of the
        /// window minus the reply reserve.
        func compactionThreshold(percent: Int) -> Int {
            max(0, (tokens - ClaudeSetupRecommendation.replyReserve) * percent / 100)
        }
    }

    var baseURL: String
    var opusID: String
    var sonnetID: String
    var haikuID: String
    var localIDEnabled: Bool
    var compactPercent: Int
    /// Keyed by the id Claude Code asks for.
    var windows: [String: Window]

    /// Tokens Claude Code holds back for the reply.
    static let replyReserve = 20_000
    /// From this window on an id carries `[1m]`.
    static let oneMillion = 1_000_000

    /// The key of an id's saved settings, and what goes on the wire: the id
    /// without `[1m]`, which Claude Code strips before sending.
    static func settingsKey(for id: String) -> String { ClaudeSetupSettings.withoutOneM(id) }
    /// The global cap to recommend: the largest window among the ids without
    /// `[1m]`, which is the local model's unless a tier is routed under a
    /// million. `[1m]` ids ignore `CLAUDE_CODE_MAX_CONTEXT_TOKENS`; every
    /// other id takes it, so it protects `local` and any id typed by hand.
    /// nil when there is no local id: nothing for it to protect.
    var contextCap: Int? {
        guard localIDEnabled, let local = ids.first(where: { $0.role == "local" }),
              let window = windows[local.id] else { return nil }
        return max(window.tokens, bareTierFloor)
    }

    /// The largest window among the tier ids without `[1m]`.
    var bareTierFloor: Int {
        ids.filter { $0.role != "local" && !$0.id.lowercased().hasSuffix("[1m]") }
            .compactMap { windows[$0.id]?.tokens }.max() ?? 0
    }
    /// The smallest window Claude Code accepts for one model.
    static let minimumWindow = 100_000

    /// The ids in the order they are written and listed: the three tiers,
    /// then `local` while it is on.
    var ids: [(role: String, id: String)] {
        var list = [("opus", opusID), ("sonnet", sonnetID), ("haiku", haikuID)]
        if localIDEnabled { list.append(("local", ClaudeSetupSettings.localID)) }
        return list
    }

    /// An id's window: a window set in ZGate wins, then the context length
    /// splash reports for the routed model, then the default.
    static func make(
        settings: ClaudeSetupSettings,
        boundPort: Int?,
        configuredPort: Int,
        target: (String) -> ClaudeSetupTarget?,
        splashModels: [SplashModelInfo]
    ) -> ClaudeSetupRecommendation {
        let roles = ClaudeSetupSettings.roles.filter { $0 != "local" || settings.localIDEnabled }
        var windows: [String: Window] = [:]
        var ids: [String: String] = [:]
        for role in roles {
            // Routes are keyed by what goes on the wire.
            let base = ClaudeSetupSettings.withoutOneM(settings.id(for: role))
            let window: Window
            if let set = settings.contextWindows[role] {
                window = Window(tokens: max(set, minimumWindow), source: .setHere)
            } else if let route = target(base), route.isSplash, let model = route.model,
                      let length = splashModels.first(where: { $0.id == model })?.contextLength {
                window = Window(tokens: max(length, minimumWindow), source: .splash)
            } else {
                window = Window(tokens: max(settings.defaultContextWindow, minimumWindow), source: .defaultWindow)
            }
            // `[1m]` pins the id's window to 1M, whatever CLAUDE_CODE_MAX_CONTEXT_TOKENS
            // says: a stale one in a session's environment cannot shrink it. Under a
            // million the id stays bare — the suffix would pin it too high.
            let id = window.tokens >= oneMillion ? base + "[1m]" : base
            windows[id] = window
            ids[role] = id
        }
        return ClaudeSetupRecommendation(
            baseURL: "http://127.0.0.1:\(boundPort ?? configuredPort)",
            opusID: ids["opus"] ?? "opus", sonnetID: ids["sonnet"] ?? "sonnet",
            haikuID: ids["haiku"] ?? "haiku",
            localIDEnabled: settings.localIDEnabled,
            compactPercent: min(100, max(1, settings.compactPercent)),
            windows: windows)
    }
}

// MARK: - Changes

/// One key the configurator would write, remove, rename or copy.
struct ClaudeSettingsChange: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case set, remove, rename, copy }

    var kind: Kind
    /// Path of the key, e.g. `["env", "ANTHROPIC_BASE_URL"]`.
    var path: [String]
    /// The value before the change, as text; nil when the key was absent.
    var previous: String?
    /// The value after: the new value for `set`; nil for `remove`.
    var value: String?
    /// Whether `value` is written as a JSON number.
    var number: Bool = false
    /// The destination path of `rename` and `copy`.
    var destination: [String]?

    var id: String { "\(kind) \(path.joined(separator: ".")) \(destination ?? [])" }
    var label: String { path.joined(separator: ".") }
}

// MARK: - Planner

/// From "what the file says" to "what ZGate recommends". Pure: the caller
/// reads the file, plans, shows the plan, and writes it in one transaction.
enum ClaudeSetupPlanner {

    /// Everything that differs, in the order it is applied: the saved
    /// per-model settings follow their id, then the environment keys and the
    /// windows are written, then what has to go is removed.
    static func changes(for document: JSONNode, recommendation: ClaudeSetupRecommendation)
        -> [ClaudeSettingsChange] {
        var root = document
        let settingsKey = "modelSettings"

        // Saved per-model settings (effort level, …) follow the id, under the
        // key without `[1m]`. The old id is what the file names for the tier
        // now; the file may already carry the suffix.
        var copies: [ClaudeSettingsChange] = []
        var renames: [ClaudeSettingsChange] = []
        for (role, id) in recommendation.ids where role != "local" {
            let key = ClaudeSetupRecommendation.settingsKey(for: id)
            let idKey = ["env", "ANTHROPIC_DEFAULT_\(role.uppercased())_MODEL"]
            guard let old = root.value(at: idKey)?.text, !old.isEmpty,
                  root.value(at: [settingsKey, key]) == nil,
                  let source = [old, ClaudeSetupSettings.withoutOneM(old)]
                      .first(where: { root.value(at: [settingsKey, $0]) != nil })
            else { continue }
            let sourcePath = [settingsKey, source]
            if renames.contains(where: { $0.path == sourcePath }) {
                // Two tiers shared one id: the second tier gets a copy.
                copies.append(ClaudeSettingsChange(kind: .copy, path: sourcePath, previous: nil,
                                                   value: nil, destination: [settingsKey, key]))
            } else {
                renames.append(ClaudeSettingsChange(kind: .rename, path: sourcePath, previous: source,
                                                    value: key, destination: [settingsKey, key]))
            }
        }
        apply(copies + renames, to: &root)

        var sets: [ClaudeSettingsChange] = []
        var removals: [ClaudeSettingsChange] = []
        func current(_ key: String) -> String? { root.value(at: ["env", key])?.text }
        func set(_ key: String, to value: String, number: Bool = false, same isSame: (String?) -> Bool) {
            let old = current(key)
            guard !isSame(old) else { return }
            sets.append(ClaudeSettingsChange(kind: .set, path: ["env", key], previous: old,
                                             value: value, number: number))
        }
        let baseURL = recommendation.baseURL
        set("ANTHROPIC_BASE_URL", to: baseURL) { $0.map { sameURL($0, baseURL) } ?? false }
        for (role, id) in recommendation.ids where role != "local" {
            set("ANTHROPIC_DEFAULT_\(role.uppercased())_MODEL", to: id) { $0 == id }
        }
        set("CLAUDE_CODE_AUTO_MODE_MODEL", to: recommendation.haikuID) { $0 == recommendation.haikuID }
        set("CLAUDE_CODE_GATEWAY_HINT_HEADERS", to: "1") { $0 == "1" }
        set("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", to: String(recommendation.compactPercent)) {
            $0 == String(recommendation.compactPercent)
        }
        let localKey = ClaudeSetupSettings.localID
        let localID = recommendation.ids.first { $0.role == "local" }?.id ?? localKey
        if recommendation.localIDEnabled {
            set("ANTHROPIC_CUSTOM_MODEL_OPTION", to: localID) {
                $0.map { ClaudeSetupSettings.withoutOneM($0) == localKey } ?? false
            }
        } else if current("ANTHROPIC_CUSTOM_MODEL_OPTION")
            .map({ ClaudeSetupSettings.withoutOneM($0) }) == localKey {
            // What an earlier apply wrote for the local id; the id is off now.
            removals.append(ClaudeSettingsChange(kind: .remove, path: ["env", "ANTHROPIC_CUSTOM_MODEL_OPTION"],
                                                 previous: localID, value: nil))
            if root.value(at: [settingsKey, localID]) != nil {
                removals.append(ClaudeSettingsChange(kind: .remove, path: [settingsKey, localID],
                                                     previous: nil, value: nil))
            }
        }

        // Each id gets the window of the model ZGate routes it to.
        for (_, id) in recommendation.ids {
            guard let window = recommendation.windows[id] else { continue }
            let path = [settingsKey, ClaudeSetupRecommendation.settingsKey(for: id), "autoCompactWindow"]
            let old = root.value(at: path)?.intValue
            if old != window.tokens {
                sets.append(ClaudeSettingsChange(kind: .set, path: path, previous: old.map(String.init),
                                                 value: String(window.tokens), number: true))
            }
        }

        // The global cap is a ceiling for every id without `[1m]`: the local
        // model's window, so `local` and any id typed by hand are protected.
        // `[1m]` ids ignore it. A lower cap is the owner's (a cost choice); a
        // higher or missing one is set. With no local id nothing needs it, and
        // one that cuts a bare tier's window goes.
        let capKey = "CLAUDE_CODE_MAX_CONTEXT_TOKENS"
        let cap = current(capKey).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let limit = recommendation.contextCap {
            if cap.map({ $0 <= limit }) != true {
                set(capKey, to: String(limit)) { _ in false }
            }
        } else if let cap, cap < recommendation.bareTierFloor {
            removals.append(ClaudeSettingsChange(kind: .remove, path: ["env", capKey],
                                                 previous: String(cap), value: nil))
        }
        return copies + renames + sets + removals
    }

    /// Writes the changes into the document. Copies run before renames so a
    /// copy can take the object a rename is about to move.
    static func apply(_ changes: [ClaudeSettingsChange], to root: inout JSONNode) {
        for change in changes where change.kind == .copy {
            guard let source = root.value(at: change.path), let destination = change.destination else { continue }
            root.set(source, at: destination)
        }
        for change in changes where change.kind == .rename {
            guard let destination = change.destination, let from = change.path.last, let to = destination.last else {
                continue
            }
            root.renameMember(ofObjectAt: Array(change.path.dropLast()), from: from, to: to)
        }
        for change in changes where change.kind == .set {
            guard let value = change.value else { continue }
            root.set(change.number ? .number(value) : .string(value), at: change.path)
        }
        for change in changes where change.kind == .remove {
            root.remove(at: change.path)
        }
    }

    private static func sameURL(_ a: String, _ b: String) -> Bool {
        func normalize(_ url: String) -> String {
            var text = url.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalize(a) == normalize(b)
    }
}

// MARK: - File store

/// The one place that writes Claude Code's settings file. Every action
/// re-reads the file; a write is one transaction: compare with the previewed
/// fingerprint, back up, then replace atomically with the original's
/// permissions. The file holds secrets, so its bytes are never kept.
struct ClaudeSettingsFileStore: Sendable {
    enum ReadError: Error, Equatable {
        case missing
        case unreadable(String)
        case invalidJSON(String)
    }

    enum WriteError: Error, Equatable {
        case read(ReadError)
        case changedSincePreview
        case io(String)
    }

    /// What the file said when it was read. `fingerprint` is what a write
    /// must find again.
    struct Snapshot: Sendable {
        let root: JSONNode
        let style: JSONStyle
        let fingerprint: String
        let mode: Int
    }

    static let backupPrefix = "settings.json.zgate-backup-"
    static let backupsKept = 10

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/.claude/settings.json`, or `settings.json` in `$CLAUDE_CONFIG_DIR`.
    static func defaultFileURL(configDir: URL?) -> URL {
        let dir = configDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        return dir.appendingPathComponent("settings.json")
    }

    func read() throws -> Snapshot {
        let loaded = try load()
        return Snapshot(root: loaded.document.root, style: loaded.document.style,
                        fingerprint: loaded.fingerprint, mode: loaded.mode)
    }

    /// Writes the changes. `fingerprint` is the one read at the preview; nil
    /// when the file was missing then. Returns the backup's name, or nil when
    /// nothing had to be written.
    @discardableResult
    func apply(_ changes: [ClaudeSettingsChange], expecting fingerprint: String?) throws -> String? {
        guard !changes.isEmpty else { return nil }
        do {
            let loaded = try load()
            guard loaded.fingerprint == fingerprint else { throw WriteError.changedSincePreview }
            var document = loaded.document
            ClaudeSetupPlanner.apply(changes, to: &document.root)
            let output = document.data
            guard output != loaded.data else { return nil }
            let backup = try backUp(loaded.data)
            try replace(with: output, mode: loaded.mode)
            return backup
        } catch ReadError.missing {
            guard fingerprint == nil else { throw WriteError.changedSincePreview }
            var document = JSONText.empty()
            ClaudeSetupPlanner.apply(changes, to: &document.root)
            try replace(with: document.data, mode: 0o600)
            return nil
        } catch let error as ReadError {
            throw WriteError.read(error)
        }
    }

    /// Puts a backup back. The current file is backed up first. Returns that
    /// backup's name, or nil when nothing had to be written.
    @discardableResult
    func restore(_ backup: URL, expecting fingerprint: String?) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: backup)
            _ = try JSONText(parsing: data)
        } catch {
            throw WriteError.io("The backup is missing or is not a settings file.")
        }
        do {
            let loaded = try load()
            guard loaded.fingerprint == fingerprint else { throw WriteError.changedSincePreview }
            guard loaded.data != data else { return nil }
            let name = try backUp(loaded.data)
            try replace(with: data, mode: loaded.mode)
            return name
        } catch ReadError.missing {
            guard fingerprint == nil else { throw WriteError.changedSincePreview }
            try replace(with: data, mode: 0o600)
            return nil
        } catch let error as ReadError {
            throw WriteError.read(error)
        }
    }

    /// The backups beside the file, newest first.
    func backups() -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(Self.backupPrefix) }.sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    // MARK: - Private

    private struct Loaded {
        let data: Data
        let document: JSONText
        let fingerprint: String
        let mode: Int
    }

    private func load() throws -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { throw ReadError.missing }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ReadError.unreadable(String(describing: error))
        }
        let document: JSONText
        do {
            document = try JSONText(parsing: data)
        } catch let error as JSONParseError {
            throw ReadError.invalidJSON(error.description)
        } catch {
            throw ReadError.invalidJSON(String(describing: error))
        }
        if let problem = Self.shapeProblem(document.root) { throw ReadError.invalidJSON(problem) }
        let mode = (try? fm.attributesOfItem(atPath: fileURL.path)[.posixPermissions])
            .flatMap { ($0 as? NSNumber)?.intValue } ?? 0o600
        return Loaded(data: data, document: document, fingerprint: Self.fingerprint(data), mode: mode)
    }

    /// Claude Code's file is an object whose `env` and `modelSettings` are objects.
    static func shapeProblem(_ root: JSONNode) -> String? {
        guard root.objectMembers != nil else { return "The file is not a JSON object." }
        for key in ["env", "modelSettings"] {
            if let section = root.value(at: [key]), section.objectMembers == nil {
                return "\"\(key)\" is not an object."
            }
        }
        return nil
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the bytes beside the file under a timestamped name, keeping the
    /// newest `backupsKept`. Returns the name.
    private func backUp(_ data: Data) throws -> String {
        let directory = fileURL.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var name = Self.backupPrefix + stamp
        var suffix = 0
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            suffix += 1
            name = Self.backupPrefix + stamp + "-\(suffix)"
        }
        guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path,
                                             contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WriteError.io("Could not write the backup beside the settings file.")
        }
        for stale in backups().dropFirst(Self.backupsKept) {
            try? FileManager.default.removeItem(at: stale)
        }
        return name
    }

    /// Writes a temporary file beside the target with the given permissions,
    /// then renames it over the target: readers see either file, never a half.
    private func replace(with data: Data, mode: Int) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".settings.json.zgate-tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw WriteError.io("Could not write beside the settings file.")
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw WriteError.io(reason)
        }
    }
}
