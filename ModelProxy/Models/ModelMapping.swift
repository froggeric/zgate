import Foundation

/// A single global model routing rule.
/// Maps one Anthropic source model to a vendor-specific target model.
/// Global across all clients — routing rules do not differ by tool.
struct ModelMapping: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Anthropic model ID to match exactly, e.g. "claude-haiku-4-5".
    var sourceModel: String
    /// Vendor-specific model name to substitute, e.g. "qwen-turbo".
    var targetModel: String
    /// UUID of the Vendor to route to.
    var targetVendorID: UUID
    /// Backup vendor-specific model name for failover.
    var backupTargetModel: String?
    /// UUID of the backup Vendor for failover.
    var backupTargetVendorID: UUID?
    /// Whether this routing rule participates in runtime routing.
    var isEnabled: Bool
    /// Class-pattern match (spec §2): when set, the rule matches any model
    /// whose class equals this value instead of `sourceModel` exactly.
    /// `sourceModel` then serves as a display label only.
    var matchClass: ModelClass?
    /// Terminal fallback rule: matches every model that no earlier rule
    /// matched (evaluated after all class rules; spec §2 "terminal fallback").
    var catchAll: Bool
    /// ALL must hold for the rule to serve a request (nil/empty = always).
    var conditions: [RuleCondition]?

    init(
        id: UUID = UUID(),
        sourceModel: String,
        targetModel: String,
        targetVendorID: UUID,
        backupTargetModel: String? = nil,
        backupTargetVendorID: UUID? = nil,
        isEnabled: Bool = true,
        matchClass: ModelClass? = nil,
        catchAll: Bool = false,
        conditions: [RuleCondition]? = nil
    ) {
        self.id = id
        self.sourceModel = sourceModel
        self.targetModel = targetModel
        self.targetVendorID = targetVendorID
        self.backupTargetModel = backupTargetModel
        self.backupTargetVendorID = backupTargetVendorID
        self.isEnabled = isEnabled
        self.matchClass = matchClass
        self.catchAll = catchAll
        self.conditions = conditions
    }

    // MARK: - Codable (legacy-tolerant)

    enum CodingKeys: String, CodingKey {
        case id, sourceModel, targetModel, targetVendorID
        case backupTargetModel, backupTargetVendorID, isEnabled
        case matchClass, catchAll, conditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceModel = try c.decode(String.self, forKey: .sourceModel)
        targetModel = try c.decode(String.self, forKey: .targetModel)
        targetVendorID = try c.decode(UUID.self, forKey: .targetVendorID)
        backupTargetModel = try? c.decode(String.self, forKey: .backupTargetModel)
        backupTargetVendorID = try? c.decode(UUID.self, forKey: .backupTargetVendorID)
        if c.contains(.isEnabled) {
            isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        } else {
            isEnabled = true
        }
        matchClass = try? c.decode(ModelClass.self, forKey: .matchClass)
        catchAll = (try? c.decode(Bool.self, forKey: .catchAll)) ?? false
        conditions = try? c.decode([RuleCondition].self, forKey: .conditions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceModel, forKey: .sourceModel)
        try c.encode(targetModel, forKey: .targetModel)
        try c.encode(targetVendorID, forKey: .targetVendorID)
        try c.encodeIfPresent(backupTargetModel, forKey: .backupTargetModel)
        try c.encodeIfPresent(backupTargetVendorID, forKey: .backupTargetVendorID)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(matchClass, forKey: .matchClass)
        // Legacy shape: absent when false (decode defaults false), so a
        // plain rule re-saved by the app doesn't grow a new field.
        if catchAll {
            try c.encode(catchAll, forKey: .catchAll)
        }
        try c.encodeIfPresent(conditions, forKey: .conditions)
    }
}

enum ModelMappingActivation {
    static func setEnabled(_ isEnabled: Bool, for id: UUID, in mappings: inout [ModelMapping]) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].isEnabled = isEnabled
        guard isEnabled else { return }
        enforceSingleEnabledSource(for: id, in: &mappings)
    }

    static func enforceSingleEnabledSource(for id: UUID, in mappings: inout [ModelMapping]) {
        guard let index = mappings.firstIndex(where: { $0.id == id }),
              mappings[index].isEnabled else { return }
        let sourceModel = mappings[index].sourceModel.trimmingCharacters(in: .whitespaces)
        for mappingIndex in mappings.indices where mappings[mappingIndex].id != id {
            if mappings[mappingIndex].sourceModel.trimmingCharacters(in: .whitespaces) == sourceModel {
                mappings[mappingIndex].isEnabled = false
            }
        }
    }
}
