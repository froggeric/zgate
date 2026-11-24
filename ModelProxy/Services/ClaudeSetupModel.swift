import Foundation
import Observation

/// The configurator's state for the Settings section. Every action re-reads
/// the file; writes go through `ClaudeSettingsFileStore`, never around it.
@MainActor
@Observable
final class ClaudeSetupModel {

    /// What the model needs from the app to recommend.
    struct Context: Equatable {
        var settings = ClaudeSetupSettings()
        var configuredPort = 8787
        var boundPort: Int?
        /// Where each id Claude Code asks for is routed right now.
        var targets: [String: ClaudeSetupTarget] = [:]
        var splashPort = 8123

        /// From the live config: the Claude client's port, and each id's
        /// primary target as a routing snapshot built from the config resolves it.
        static func from(config: AppConfig, boundPorts: [String: Int]) -> Context {
            let settings = config.claudeSetup ?? ClaudeSetupSettings()
            let client = config.clients.first { $0.clientName.lowercased().contains("claude") }
            var context = Context(
                settings: settings,
                configuredPort: client?.port ?? 8787,
                boundPort: client.flatMap { boundPorts[$0.clientName] },
                splashPort: config.splash?.port ?? 8123)
            guard let client else { return context }
            let vendors = AppConfig.syncingSplashVendor(config.vendors, splashPort: config.splash?.port)
            let snapshot = RoutingSnapshot(from: config, for: client, vendors: vendors)
            for role in ClaudeSetupSettings.roles where role != "local" || settings.localIDEnabled {
                let id = ClaudeSetupSettings.withoutOneM(settings.id(for: role))
                guard let target = snapshot.targets(for: id)?.first else { continue }
                context.targets[id] = ClaudeSetupTarget(
                    model: target.targetModel,
                    isSplash: AppConfig.isSplashVendor(name: target.vendorName, baseURL: target.baseURL),
                    vendor: target.vendorName)
            }
            return context
        }
    }

    private(set) var review = ClaudeSetupReview.empty
    /// What the file was when it was read; a write must find it again.
    private(set) var fingerprint: String?
    private(set) var backups: [URL] = []
    private(set) var lastBackup: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    let store: ClaudeSettingsFileStore

    private let splashClient: SplashModelsClient
    private var context = Context()
    private var splashModels: [SplashModelInfo] = []

    /// With no store, the file is Claude Code's own: `settings.json` in
    /// `$CLAUDE_CONFIG_DIR`, or in `~/.claude`.
    init(store: ClaudeSettingsFileStore? = nil, splashClient: SplashModelsClient? = nil) {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        self.store = store ?? ClaudeSettingsFileStore(fileURL: ClaudeSettingsFileStore.defaultFileURL(configDir: configDir))
        self.splashClient = splashClient ?? SplashModelsClient()
    }

    var filePath: String { store.fileURL.path }

    /// Reads the file and rebuilds the review.
    func refresh(context: Context) async {
        self.context = context
        isLoading = true
        defer { isLoading = false }
        // Splash's context lengths only matter once an id routes there.
        if context.targets.values.contains(where: \.isSplash) {
            splashModels = await splashClient.models(baseURL: SplashModelsClient.endpoint(port: context.splashPort))
        } else {
            splashModels = []
        }
        let recommendation = ClaudeSetupRecommendation.make(
            settings: context.settings, boundPort: context.boundPort, configuredPort: context.configuredPort,
            target: { context.targets[$0] }, splashModels: splashModels)
        do {
            let snapshot = try store.read()
            fingerprint = snapshot.fingerprint
            review = ClaudeSetupReviewer.review(document: snapshot.root, readError: nil,
                                                recommendation: recommendation, targets: context.targets)
        } catch let error as ClaudeSettingsFileStore.ReadError {
            // A file that could not be read has no fingerprint to expect.
            fingerprint = nil
            review = ClaudeSetupReviewer.review(document: nil, readError: error,
                                                recommendation: recommendation, targets: context.targets)
        } catch {
            errorMessage = String(describing: error)
        }
        backups = store.backups()
        lastBackup = backups.first?.lastPathComponent
    }

    /// Writes the reviewed changes, then reads the file again.
    func apply() async {
        perform { try store.apply(review.changes, expecting: fingerprint) }
        await refresh(context: context)
    }

    /// Puts the newest backup back, then reads the file again.
    func restoreLastBackup() async {
        guard let backup = backups.first else { return }
        perform { try store.restore(backup, expecting: fingerprint) }
        await refresh(context: context)
    }

    // MARK: - Private

    /// Runs one store action and turns its failure into a line for the section.
    private func perform(_ action: () throws -> String?) {
        errorMessage = nil
        do {
            if let name = try action() { lastBackup = name }
        } catch let error as ClaudeSettingsFileStore.WriteError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private static func message(for error: ClaudeSettingsFileStore.WriteError) -> String {
        switch error {
        case .changedSincePreview:
            return "The file changed since this preview. Nothing was written; the list below is recalculated."
        case .read(.invalidJSON(let reason)):
            return "Nothing was written: the file is not valid JSON (\(reason))."
        case .read(.unreadable(let reason)):
            return "Nothing was written: the file could not be read (\(reason))."
        case .read(.missing):
            return "Nothing was written: the file is missing."
        case .io(let reason):
            return "The file was left as it was: \(reason)"
        }
    }
}

/// The `local` routing rule behind the configurator's local model id:
/// `local` → the active splash profile's model, relay Flash as the backup.
enum ClaudeSetupLocalRule {

    static let backupModel = "GLM-5.3-Flash"

    static func rule(in config: AppConfig) -> ModelMapping? {
        let localID = ClaudeSetupSettings.localID
        return config.modelMappings.first { $0.sourceModel == localID && $0.matchClass == nil && !$0.catchAll }
    }

    /// The model of the active splash profile.
    static func activeModel(in config: AppConfig) -> String? {
        guard let settings = config.splash else { return nil }
        return settings.profiles.first { $0.id == settings.activeProfileID }?.model
    }

    /// True when the rule sends `local` to a model other than the active one.
    static func isStale(in config: AppConfig) -> Bool {
        guard let rule = rule(in: config) else { return false }
        return rule.targetModel != activeModel(in: config)
    }

    /// Points the rule at the active profile's model, creating it with the
    /// other routes (not behind the catch-all) when absent. Returns true when
    /// the config changed; the caller saves it.
    @discardableResult
    static func sync(into config: AppConfig) -> Bool {
        let localID = ClaudeSetupSettings.localID
        guard let model = activeModel(in: config), !model.isEmpty,
              let splashVendor = config.vendors.first(where: { AppConfig.isSplashVendor($0) }) else {
            return false
        }
        let relay = config.vendors.first { $0.vendorKind == .relay }
        let backup = relay == nil ? nil : backupModel
        if let index = config.modelMappings.firstIndex(where: {
            $0.sourceModel == localID && $0.matchClass == nil && !$0.catchAll
        }) {
            let rule = config.modelMappings[index]
            guard rule.targetModel != model || rule.targetVendorID != splashVendor.id
                || rule.backupTargetModel != backup || rule.backupTargetVendorID != relay?.id else {
                return false
            }
            config.modelMappings[index].targetModel = model
            config.modelMappings[index].targetVendorID = splashVendor.id
            config.modelMappings[index].backupTargetModel = backup
            config.modelMappings[index].backupTargetVendorID = relay?.id
            return true
        }
        let rule = ModelMapping(
            sourceModel: localID, targetModel: model, targetVendorID: splashVendor.id,
            backupTargetModel: backup, backupTargetVendorID: relay?.id)
        if let catchAll = config.modelMappings.firstIndex(where: { $0.catchAll }) {
            config.modelMappings.insert(rule, at: catchAll)
        } else {
            config.modelMappings.append(rule)
        }
        config.localRuleSeeded = true
        return true
    }
}
