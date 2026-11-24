import Foundation

/// What the Settings section shows: the file against the recommendation.
struct ClaudeSetupReview: Equatable {
    enum State: Equatable { case upToDate, differs, noSettingsFile, unreadable(String) }

    /// One managed key as the section lists it.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let current: String
        let recommended: String
        let differs: Bool
    }

    /// One id Claude Code asks for: its window, where the window comes from,
    /// and the token count compaction runs at.
    struct IDLine: Identifiable, Equatable {
        let id: String
        let modelID: String
        let window: Int
        let threshold: Int
        let source: ClaudeSetupRecommendation.Window.Source
        let target: String?
    }

    var state: State
    var changes: [ClaudeSettingsChange]
    var rows: [Row]
    var ids: [IDLine]
    /// What is checked and never written: a missing sign-in, keys that
    /// switch compaction off or ignore `[1m]`, a `local` id without its rule.
    var warnings: [String]

    static let empty = ClaudeSetupReview(
        state: .unreadable(""), changes: [], rows: [], ids: [], warnings: [])

    var canApply: Bool {
        switch state {
        case .upToDate, .unreadable: return false
        case .differs, .noSettingsFile: return !changes.isEmpty
        }
    }
}

enum ClaudeSetupReviewer {

    /// `document` is nil when the file could not be read; `readError` says
    /// why. A missing file is still planned, so "Apply" can create it.
    static func review(
        document: JSONNode?,
        readError: ClaudeSettingsFileStore.ReadError?,
        recommendation: ClaudeSetupRecommendation,
        targets: [String: ClaudeSetupTarget]
    ) -> ClaudeSetupReview {
        let idLines = self.idLines(recommendation, targets)
        guard let document else {
            if case .missing = readError {
                let empty = JSONNode.object(members: [])
                let changes = ClaudeSetupPlanner.changes(for: empty, recommendation: recommendation)
                return ClaudeSetupReview(
                    state: .noSettingsFile, changes: changes,
                    rows: rows(document: empty, changes: changes, recommendation: recommendation),
                    ids: idLines,
                    warnings: warnings(document: empty, recommendation: recommendation, targets: targets))
            }
            let reason: String
            switch readError {
            case .invalidJSON(let text), .unreadable(let text): reason = text
            case .missing, .none: reason = "The file could not be read."
            }
            return ClaudeSetupReview(state: .unreadable(reason), changes: [], rows: [], ids: idLines,
                                     warnings: [])
        }
        let changes = ClaudeSetupPlanner.changes(for: document, recommendation: recommendation)
        return ClaudeSetupReview(
            state: changes.isEmpty ? .upToDate : .differs,
            changes: changes,
            rows: rows(document: document, changes: changes, recommendation: recommendation),
            ids: idLines,
            warnings: warnings(document: document, recommendation: recommendation, targets: targets))
    }

    /// Thousands separated by commas, whatever the system locale.
    static func formatted(_ number: Int) -> String {
        number.formatted(IntegerFormatStyle<Int>().locale(Locale(identifier: "en_US")))
    }

    // MARK: - Private

    private static func idLines(_ recommendation: ClaudeSetupRecommendation,
                                _ targets: [String: ClaudeSetupTarget]) -> [ClaudeSetupReview.IDLine] {
        recommendation.ids.map { role, id in
            let window = recommendation.windows[id]
            // Routes are keyed by what goes on the wire.
            let target = targets[ClaudeSetupRecommendation.settingsKey(for: id)].map {
                "\($0.model ?? "the vendor's default model") @ \($0.vendor ?? "an unknown vendor")"
            }
            return ClaudeSetupReview.IDLine(
                id: role, modelID: id, window: window?.tokens ?? 0,
                threshold: window?.compactionThreshold(percent: recommendation.compactPercent) ?? 0,
                source: window?.source ?? .defaultWindow, target: target)
        }
    }

    private static func rows(document: JSONNode, changes: [ClaudeSettingsChange],
                             recommendation: ClaudeSetupRecommendation) -> [ClaudeSetupReview.Row] {
        var rows: [ClaudeSetupReview.Row] = []
        func key(_ path: [String], _ title: String, current: String, recommended: String) {
            rows.append(ClaudeSetupReview.Row(
                id: path.joined(separator: "."), title: title, current: current, recommended: recommended,
                differs: changes.contains { $0.path == path }))
        }
        func env(_ name: String, _ title: String, recommended: String) {
            key(["env", name], title, current: document.value(at: ["env", name])?.text ?? "not set",
                recommended: recommended)
        }
        env("ANTHROPIC_BASE_URL", "Base URL", recommended: recommendation.baseURL)
        for (role, id) in recommendation.ids where role != "local" {
            env("ANTHROPIC_DEFAULT_\(role.uppercased())_MODEL", "\(role.capitalized) tier", recommended: id)
        }
        env("CLAUDE_CODE_AUTO_MODE_MODEL", "Auto-mode model", recommended: recommendation.haikuID)
        env("CLAUDE_CODE_GATEWAY_HINT_HEADERS", "Gateway hint headers", recommended: "1")
        env("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "Compaction percentage",
            recommended: String(recommendation.compactPercent))
        // The cap is a ceiling for every id without `[1m]`: recommended at the
        // local model's window; a lower one is the owner's.
        let capPath = ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
        let cap = document.value(at: capPath)?.text
        let capRecommended: String
        if let change = changes.first(where: { $0.path == capPath }) {
            capRecommended = change.value ?? "not set"
        } else if let cap, let limit = recommendation.contextCap,
                  Int(cap).map({ $0 <= limit }) == true {
            capRecommended = "kept (yours)"
        } else {
            capRecommended = cap ?? recommendation.contextCap.map(String.init) ?? "not set"
        }
        key(capPath, "Context cap (ids without [1m])", current: cap ?? "not set",
            recommended: capRecommended)
        if recommendation.localIDEnabled {
            env("ANTHROPIC_CUSTOM_MODEL_OPTION", "Custom model option", recommended: ClaudeSetupSettings.localID)
        }
        for (_, id) in recommendation.ids {
            guard let window = recommendation.windows[id] else { continue }
            let path = ["modelSettings", ClaudeSetupRecommendation.settingsKey(for: id), "autoCompactWindow"]
            let current = document.value(at: path)?.intValue
            key(path, "\(id) context window", current: current.map { formatted($0) } ?? "not set",
                recommended: formatted(window.tokens))
        }
        return rows
    }

    private static func warnings(document: JSONNode, recommendation: ClaudeSetupRecommendation,
                                 targets: [String: ClaudeSetupTarget]) -> [String] {
        var warnings: [String] = []
        func has(_ path: [String]) -> Bool {
            guard let text = document.value(at: path)?.text else { return false }
            return !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let signedIn = has(["env", "ANTHROPIC_AUTH_TOKEN"]) || has(["env", "ANTHROPIC_API_KEY"])
            || has(["apiKeyHelper"])
        if !signedIn {
            warnings.append("Claude Code has no sign-in: none of ANTHROPIC_AUTH_TOKEN, "
                            + "ANTHROPIC_API_KEY and apiKeyHelper is set.")
        }
        for name in ["CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT", "DISABLE_COMPACT"] {
            let value = document.value(at: ["env", name])?.text?.lowercased()
            if value == "1" || value == "true" {
                warnings.append("\(name) switches proactive compaction off. "
                                + "Remove it for the percentage to apply.")
            }
        }
        let ignoreOneM = document.value(at: ["env", "CLAUDE_CODE_DISABLE_1M_CONTEXT"])?.text?.lowercased()
        if ignoreOneM == "1" || ignoreOneM == "true" {
            warnings.append("CLAUDE_CODE_DISABLE_1M_CONTEXT ignores [1m] and holds every model to a "
                            + "200K window. Remove it.")
        }
        if document.value(at: ["autoCompactEnabled"]) == .bool(false) {
            warnings.append("\"autoCompactEnabled\": false switches automatic compaction off.")
        }
        if recommendation.localIDEnabled, targets[ClaudeSetupSettings.localID]?.isSplash != true {
            warnings.append("No routing rule sends \"local\" to the local model: "
                            + "a \"local\" request is answered by the catch-all.")
        }
        return warnings
    }
}
