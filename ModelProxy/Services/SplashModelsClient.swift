import Foundation

/// One resident model reported by splash's `/v1/models` (spec §3.3).
struct SplashModelInfo: Equatable, Sendable, Identifiable {
    let id: String
    let contextLength: Int?
    let vision: Bool
    let reasoningEfforts: [String]
}

/// Discovery client for the profile editor's live dropdown. Failure of any
/// kind (server down, malformed payload) yields `[]` — free text still works.
struct SplashModelsClient: Sendable {
    /// Legacy default kept for reference; the live endpoint derives from
    /// SplashSettings.port (default 8123 since 2026-11-18 — was 8000).
    static func endpoint(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/models")!
    }

    let fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { url in
        let (d, _) = try await URLSession.shared.data(from: url); return d
    }) {
        self.fetch = fetch
    }

    func models(baseURL: URL? = nil) async -> [SplashModelInfo] {
        let baseURL = baseURL ?? Self.endpoint(port: 8123)
        guard let data = try? await fetch(baseURL) else { return [] }
        struct Wire: Decodable {
            struct Entry: Decodable {
                let id: String?
                let context_length: Int?
                let vision: Bool?
                struct Reasoning: Decodable { let efforts: [String]? }
                let reasoning: Reasoning?
            }
            struct Legacy: Decodable { let name: String? }
            let data: [Entry]?
            let models: [Legacy]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
        if let entries = wire.data, !entries.isEmpty {
            return entries.compactMap { e in
                guard let id = e.id else { return nil }
                return SplashModelInfo(
                    id: id, contextLength: e.context_length,
                    vision: e.vision ?? false,
                    reasoningEfforts: e.reasoning?.efforts ?? [])
            }
        }
        return (wire.models ?? []).compactMap { l in
            l.name.map { SplashModelInfo(id: $0, contextLength: nil, vision: false, reasoningEfforts: []) }
        }
    }
}
