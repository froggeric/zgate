import Foundation
import Testing
@testable import ZGate

/// The values the configurator recommends for Claude Code's settings file
/// (owner requirements of 2026-11-23: GLM at 1M, a local model at its own
/// window, compaction at a percentage of the window, ids that stay valid).
@MainActor
@Suite struct ClaudeSetupRecommendationTests {

    private let relay = ClaudeSetupTarget(model: "GLM-5.4", isSplash: false)
    @MainActor private let qwen = SplashModelInfo(id: "local/qwen3.8-27b-q8", contextLength: 262144,
                                       vision: true, reasoningEfforts: [])

    private func make(_ settings: ClaudeSetupSettings = ClaudeSetupSettings(),
                      targets: [String: ClaudeSetupTarget] = [:],
                      splash: [SplashModelInfo]? = nil,
                      boundPort: Int? = 8787) -> ClaudeSetupRecommendation {
        ClaudeSetupRecommendation.make(settings: settings, boundPort: boundPort, configuredPort: 8787,
                                       target: { targets[$0] }, splashModels: splash ?? [qwen])
    }

    private func splashTarget(_ model: String) -> ClaudeSetupTarget {
        ClaudeSetupTarget(model: model, isSplash: true)
    }

    @Test func windowFollowsTheModelZGateRoutesTheIDTo() {
        let rec = make(ClaudeSetupSettings(localIDEnabled: true), targets: [
            "opus": relay, "haiku": splashTarget("local/qwen3.8-27b-q8"),
            "local": splashTarget("local/qwen3.8-27b-q8"),
        ])
        #expect(rec.windows["opus[1m]"] == .init(tokens: 1_000_000, source: .defaultWindow))
        #expect(rec.windows["sonnet[1m]"] == .init(tokens: 1_000_000, source: .defaultWindow))
        // Under a million the id stays bare: [1m] would pin it to 1M.
        #expect(rec.windows["haiku"] == .init(tokens: 262144, source: .splash))
        #expect(rec.windows["local"] == .init(tokens: 262144, source: .splash))
        #expect(rec.haikuID == "haiku")
    }

    @Test func theGlobalCapIsTheLocalModelsWindow() {
        // [1m] ids ignore CLAUDE_CODE_MAX_CONTEXT_TOKENS; `local` and any id typed
        // by hand take it, so it is set to the local model's window.
        let on = make(ClaudeSetupSettings(localIDEnabled: true),
                      targets: ["local": splashTarget("local/qwen3.8-27b-q8")])
        #expect(on.contextCap == 262_144)
        #expect(make().contextCap == nil, "no local id, nothing for the cap to protect")
    }

    @Test func aBareTierRaisesTheCapAboveTheLocalWindow() {
        // A tier routed under a million carries no [1m]; the cap must not cut it.
        let settings = ClaudeSetupSettings(localIDEnabled: true, defaultContextWindow: 400_000)
        let rec = make(settings, targets: ["local": splashTarget("local/qwen3.8-27b-q8")])
        #expect(rec.opusID == "opus" && rec.localIDEnabled)
        #expect(rec.contextCap == 400_000)
    }

    @Test func aWindowSetHereWinsOverTheRoute() {
        let rec = make(ClaudeSetupSettings(contextWindows: ["opus": 400_000]), targets: ["opus": relay])
        #expect(rec.windows["opus"] == .init(tokens: 400_000, source: .setHere))
        #expect(rec.opusID == "opus")
    }

    @Test func aSplashModelWithoutAKnownLengthFallsBackToTheDefault() {
        let rec = make(targets: ["haiku": splashTarget("some/other-model")])
        #expect(rec.windows["haiku[1m]"] == .init(tokens: 1_000_000, source: .defaultWindow))
        #expect(rec.haikuID == "haiku[1m]")
    }

    @Test func aSmallModelIsRaisedToTheSmallestWindowClaudeCodeAccepts() {
        let small = SplashModelInfo(id: "tiny", contextLength: 32768, vision: false, reasoningEfforts: [])
        let rec = make(ClaudeSetupSettings(localIDEnabled: true), targets: ["local": splashTarget("tiny")],
                       splash: [small])
        #expect(rec.windows["local"] == .init(tokens: 100_000, source: .splash))
    }

    @Test func compactionRunsAtThePercentageOfTheWindowMinusTheReplyReserve() {
        // Measured on Claude Code 2.1.323: the window less 20,000, times the percentage.
        #expect(ClaudeSetupRecommendation.Window(tokens: 1_000_000, source: .defaultWindow)
            .compactionThreshold(percent: 70) == 686_000)
        #expect(ClaudeSetupRecommendation.Window(tokens: 262_144, source: .splash)
            .compactionThreshold(percent: 70) == 169_500)
    }

    @Test func baseURLUsesTheBoundPortAndFallsBackToTheConfiguredOne() {
        #expect(make(boundPort: 8790).baseURL == "http://127.0.0.1:8790")
        #expect(make(boundPort: nil).baseURL == "http://127.0.0.1:8787")
    }

    @Test(arguments: [(0, 1), (70, 70), (150, 100)])
    func percentageStaysBetweenOneAndAHundred(_ pair: (Int, Int)) {
        #expect(make(ClaudeSetupSettings(compactPercent: pair.0)).compactPercent == pair.1)
    }

    @Test func theDefaultsCarryTheOneMSuffixAndNoLocalID() {
        // [1m] pins an id's window to 1M whatever CLAUDE_CODE_MAX_CONTEXT_TOKENS says.
        let rec = make()
        #expect(rec.opusID == "opus[1m]" && rec.sonnetID == "sonnet[1m]" && rec.haikuID == "haiku[1m]")
        #expect(rec.compactPercent == 70)
        #expect(rec.windows["local"] == nil)
        #expect(rec.windows.count == 3)
        // Saved settings and the wire id go without the suffix.
        #expect(ClaudeSetupRecommendation.settingsKey(for: "opus[1m]") == "opus")
        #expect(ClaudeSetupRecommendation.settingsKey(for: "local") == "local")
    }

    @Test(arguments: ["opus", "opus[1m]", " opus "])
    func theSuffixIsWrittenOnceAndFollowsTheWindow(_ typed: String) {
        #expect(make(ClaudeSetupSettings(opusID: typed)).opusID == "opus[1m]")
        // A smaller window must not carry [1m].
        #expect(make(ClaudeSetupSettings(opusID: typed, contextWindows: ["opus": 400_000])).opusID == "opus")
    }
}

@MainActor
@Suite struct ClaudeSetupSettingsCodableTests {

    /// Same layout as ConfigStore's writer.
    private static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    @Test func absentKeysFallBackToTheDefaults() throws {
        let settings = try JSONDecoder().decode(ClaudeSetupSettings.self, from: Data(#"{"compactPercent": 65}"#.utf8))
        #expect(settings == ClaudeSetupSettings(compactPercent: 65))
    }

    @Test func aConfigWithoutTheSectionStaysByteStable() throws {
        let config = AppConfig(clients: [ClientConfig(clientName: "Claude Code", port: 8787, defaultUpstream: "x")])
        let plain = try Self.pretty.encode(config)
        let edited = config
        edited.claudeSetup = ClaudeSetupSettings()
        #expect(try Self.pretty.encode(edited) == plain)
        edited.claudeSetup?.compactPercent = 65
        edited.localRuleSeeded = true
        let text = String(decoding: try Self.pretty.encode(edited), as: UTF8.self)
        #expect(text.contains("\"compactPercent\" : 65"))
        #expect(text.contains("\"localRuleSeeded\" : true"))
        let back = try JSONDecoder().decode(AppConfig.self, from: Data(text.utf8))
        #expect(back.claudeSetup?.compactPercent == 65)
        #expect(back.localRuleSeeded)
    }
}
