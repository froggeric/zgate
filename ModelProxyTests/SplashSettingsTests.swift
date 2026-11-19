import Foundation
import Testing
@testable import ZGate

@Suite struct SplashSettingsTests {

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    @Test func launchArgumentsSkipNilFields() {
        let p = SplashProfile(name: "m", model: "the-model")
        #expect(p.launchArguments() == ["serve", "--model", "the-model"])
        let full = SplashProfile(
            name: "f", model: "m", modelDir: "/gguf", draftModel: "/draft",
            mmproj: "/mmproj", extraArgs: ["--persistent-cache", "--max-cache-disk", "20G"])
        #expect(full.launchArguments() == [
            "serve", "--model", "m",
            "--model-dir", "/gguf", "--draft-model", "/draft", "--mmproj", "/mmproj",
            "--persistent-cache", "--max-cache-disk", "20G"])
    }

    @Test func seededProfileMatchesCurrentInvocation() {
        // Cache flags live in machine-level `storage` since 2026-11-19
        // (spec §3.6) — the effective serve argv is unchanged.
        let seeded = SplashSettings.defaultSeeded()
        let argv = seeded.activeProfile!.serveArguments(port: seeded.port, storage: seeded.storage)
        #expect(argv == [
            "serve",
            "--model", "local/qwen3.8-27b-q8",
            "--model-dir", "/Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf",
            "--draft-model", "/Volumes/ssd/ai/cache/misc/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/015e795645c74b1a0eeef3b570031fb62e769bc5",
            "--mmproj", "/Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/mmproj-F16.gguf",
            "--persistent-cache", "--cache-dir", "/Volumes/ssd/ai/cache/splash",
            "--max-cache-disk", "20G",
            "--port", "8123"])
    }

    @Test func absentSplashKeyDecodesNil() throws {
        let config = try decode(#"{"vendors":[],"clients":[]}"#)
        #expect(config.splash == nil)
    }

    @Test func roundTripIsLossless() throws {
        var config = AppConfig()
        config.splash = SplashSettings.defaultSeeded()
        let data = try JSONEncoder.prettyForTest.encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.splash == config.splash)
    }

    @Test func danglingActiveProfileFallsBackToFirst() {
        var s = SplashSettings.defaultSeeded()
        s.profiles.append(SplashProfile(name: "second", model: "x"))
        s.activeProfileID = UUID()  // dangling
        #expect(s.activeProfile?.name == "Qwen3.8-27B Q8")
    }

    @Test func decodeToleratesPartialSplashObject() throws {
        let config = try decode(#"""
        {"vendors":[],"clients":[],
         "splash":{"keepRunning":false,"profiles":[{"id":"00000000-0000-0000-0000-000000000001","name":"n","model":"m"}]}}
        """#)
        #expect(config.splash?.keepRunning == false)
        #expect(config.splash?.profiles.first?.extraArgs == [])
        #expect(config.splash?.binaryPathOverride == nil)
    }

    @Test func makeDefaultSeedsSplash() {
        #expect(AppConfig.makeDefault().splash?.profiles.first?.model == "local/qwen3.8-27b-q8")
    }
}

// Test helper used above.
extension JSONEncoder {
    static var prettyForTest: JSONEncoder { JSONEncoder() }
}
