import Foundation

/// The `disk` object of splash's `GET /status` (spec §2). Tolerant decode:
/// unknown keys (`kv_bytes`, `taken_back`, …) ignored, missing fields nil —
/// the storage section renders only what splash actually reported.
nonisolated struct SplashDiskStatus: Decodable, Equatable, Sendable {
    var capacityBytes: Int?
    var limitBytes: Int?
    var usedBytes: Int?
    var fileBytes: Int?
    var volumeAvailableBytes: Int?
    /// `no` | `budget` | `closed` — kept as the raw token.
    var writesGated: String?
    var persistent: Bool?

    enum CodingKeys: String, CodingKey {
        case capacityBytes = "capacity_bytes", limitBytes = "limit_bytes"
        case usedBytes = "used_bytes", fileBytes = "file_bytes"
        case volumeAvailableBytes = "volume_available_bytes"
        case writesGated = "writes_gated"
        case persistent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capacityBytes = try? c.decode(Int.self, forKey: .capacityBytes)
        limitBytes = try? c.decode(Int.self, forKey: .limitBytes)
        usedBytes = try? c.decode(Int.self, forKey: .usedBytes)
        fileBytes = try? c.decode(Int.self, forKey: .fileBytes)
        volumeAvailableBytes = try? c.decode(Int.self, forKey: .volumeAvailableBytes)
        writesGated = try? c.decode(String.self, forKey: .writesGated)
        persistent = try? c.decode(Bool.self, forKey: .persistent)
    }
}

/// Client for the storage section's live usage row (spec §3.6). Any
/// failure — server down, malformed payload, no `disk` key — yields nil;
/// the row simply hides. Same fetch-seam shape as `SplashModelsClient`.
nonisolated struct SplashStatusClient: Sendable {
    var fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { url in
        let (d, _) = try await URLSession.shared.data(from: url); return d
    }) {
        self.fetch = fetch
    }

    private struct Envelope: Decodable { let disk: SplashDiskStatus? }

    func diskStatus(port: Int) async -> SplashDiskStatus? {
        guard let data = try? await fetch(Self.endpoint(port: port)) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.disk
    }

    static func endpoint(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/status")!
    }
}
