import Foundation

/// Per-model token usage record.
/// `inputTokens` stays the FOLDED billing input (fresh + cache reads,
/// DP-003: cache reads bill at full input price); `cacheReadTokens` carries
/// the split so the Statistics tab can show what is fresh vs re-read context.
struct ModelTokenRecord: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int

    init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        cacheReadTokens = (try? c.decode(Int.self, forKey: .cacheReadTokens)) ?? 0
    }

    /// Fresh (uncached) input: the folded total minus cache reads.
    var freshInputTokens: Int { inputTokens - cacheReadTokens }
}

/// Daily token usage snapshot persisted to disk.
/// Key: vendor ID string -> [model ID string -> record]
struct DailyTokenSnapshot: Codable, Sendable {
    /// Calendar date string in ISO 8601 format, e.g. "2026-03-06".
    var date: String
    /// Outer key: vendor UUID string. Inner key: model ID string.
    var usageByVendorAndModel: [String: [String: ModelTokenRecord]]
    /// Token usage keyed by source model name (the model the client requested before mapping).
    /// Only populated for mapped routes; passthrough routes do not contribute here.
    var sourceModelUsage: [String: ModelTokenRecord]

    init(
        date: String,
        usageByVendorAndModel: [String: [String: ModelTokenRecord]] = [:],
        sourceModelUsage: [String: ModelTokenRecord] = [:]
    ) {
        self.date = date
        self.usageByVendorAndModel = usageByVendorAndModel
        self.sourceModelUsage = sourceModelUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        usageByVendorAndModel = try container.decode([String: [String: ModelTokenRecord]].self, forKey: .usageByVendorAndModel)
        sourceModelUsage = (try? container.decode([String: ModelTokenRecord].self, forKey: .sourceModelUsage)) ?? [:]
    }
}

/// In-memory accumulator for token stats. Managed by TokenStatsStore.
struct TokenStats: Sendable {
    /// Outer key: vendor UUID. Inner key: model ID (target model for mapped routes).
    private(set) var records: [UUID: [String: ModelTokenRecord]] = [:]
    /// Token usage keyed by source model name (pre-mapping). Only mapped routes contribute.
    private(set) var sourceModelRecords: [String: ModelTokenRecord] = [:]

    mutating func add(vendorID: UUID, modelID: String, input: Int, output: Int, cacheRead: Int = 0, sourceModel: String? = nil) {
        records[vendorID, default: [:]][modelID, default: ModelTokenRecord()].inputTokens += input
        records[vendorID, default: [:]][modelID, default: ModelTokenRecord()].outputTokens += output
        records[vendorID, default: [:]][modelID, default: ModelTokenRecord()].cacheReadTokens += cacheRead
        if let sourceModel {
            sourceModelRecords[sourceModel, default: ModelTokenRecord()].inputTokens += input
            sourceModelRecords[sourceModel, default: ModelTokenRecord()].outputTokens += output
            sourceModelRecords[sourceModel, default: ModelTokenRecord()].cacheReadTokens += cacheRead
        }
    }

    /// Restore source model records from a persisted snapshot (no vendor dependency).
    mutating func restoreSourceModelRecords(_ records: [String: ModelTokenRecord]) {
        for (model, record) in records {
            sourceModelRecords[model, default: ModelTokenRecord()].inputTokens += record.inputTokens
            sourceModelRecords[model, default: ModelTokenRecord()].outputTokens += record.outputTokens
            sourceModelRecords[model, default: ModelTokenRecord()].cacheReadTokens += record.cacheReadTokens
        }
    }

    func totalInputTokens() -> Int {
        records.values.flatMap(\.values).map(\.inputTokens).reduce(0, +)
    }

    func totalOutputTokens() -> Int {
        records.values.flatMap(\.values).map(\.outputTokens).reduce(0, +)
    }

    func totalCacheReadTokens() -> Int {
        records.values.flatMap(\.values).map(\.cacheReadTokens).reduce(0, +)
    }
}
