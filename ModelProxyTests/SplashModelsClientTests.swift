import Foundation
import Testing
@testable import ZGate

@Suite struct SplashModelsClientTests {
    private final class BundleToken {}
    private func fix(_ name: String) throws -> Data {
        let fileName = "\(name).json"
        let bundle = Bundle(for: BundleToken.self)
        let candidates = [
            bundle.resourceURL?.appendingPathComponent(fileName),
            bundle.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(fileName),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(fileName)
        ]
        for c in candidates.compactMap({ $0 }) {
            if let d = try? Data(contentsOf: c) { return d }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func decodesLiveShape() async throws {
        let payload = try fix("splash-models")
        let client = SplashModelsClient(fetch: { _ in payload })
        let models = await client.models()
        #expect(models.count == 1)
        let m = models[0]
        #expect(m.id == "local/qwen3.8-27b-q8")
        #expect(m.contextLength == 262144)
        #expect(m.vision == true)
        #expect(m.reasoningEfforts == ["low", "medium", "xhigh"])
    }

    @Test func legacyListOnlyFallsBackToNames() async {
        let payload = Data(#"""
        {"object":"list","models":[{"name":"legacy-model","description":"d"}]}
        """#.utf8)
        let client = SplashModelsClient(fetch: { _ in payload })
        let models = await client.models()
        #expect(models == [SplashModelInfo(id: "legacy-model", contextLength: nil, vision: false, reasoningEfforts: [])])
    }

    @Test func dataWinsOverLegacy() async {
        let payload = Data(#"""
        {"data":[{"id":"new","context_length":100,"vision":false,"reasoning":{"efforts":["low"]}}],
         "models":[{"name":"old"}]}
        """#.utf8)
        let client = SplashModelsClient(fetch: { _ in payload })
        #expect(await client.models().map(\.id) == ["new"])
    }

    @Test func malformedPayloadYieldsEmpty() async {
        let client = SplashModelsClient(fetch: { _ in Data("not json".utf8) })
        let models = await client.models()
        #expect(models.isEmpty)
    }
}
