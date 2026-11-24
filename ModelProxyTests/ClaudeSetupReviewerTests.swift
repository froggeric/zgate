import Foundation
import Testing
@testable import ZGate

/// What the Settings section shows: the file against the recommendation —
/// the state, one row per managed key, the lines that must never be written,
/// and the token count each id compacts at.
@Suite struct ClaudeSetupReviewerTests {

    private static let recommended = ClaudeSetupRecommendation(
        baseURL: "http://127.0.0.1:8787",
        opusID: "opus[1m]", sonnetID: "sonnet[1m]", haikuID: "haiku[1m]", localIDEnabled: true,
        compactPercent: 70,
        windows: [
            "opus[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
            "sonnet[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
            "haiku[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
            "local": .init(tokens: 262_144, source: .splash),
        ])

    private static let targets: [String: ClaudeSetupTarget] = [
        "opus": ClaudeSetupTarget(model: "GLM-5.4", isSplash: false, vendor: "zcode relay"),
        "sonnet": ClaudeSetupTarget(model: "GLM-5.4", isSplash: false, vendor: "zcode relay"),
        "haiku": ClaudeSetupTarget(model: "GLM-5.3-Flash", isSplash: false, vendor: "zcode relay"),
        "local": ClaudeSetupTarget(model: "local/qwen3.8-27b-q8", isSplash: true, vendor: "splash (local)"),
    ]

    private func review(_ text: String?) throws -> ClaudeSetupReview {
        let document = try text.map { try JSONText(parsing: $0).root }
        return ClaudeSetupReviewer.review(document: document, readError: text == nil ? .missing : nil,
                                          recommendation: Self.recommended, targets: Self.targets)
    }

    @Test func anUpToDateFileIsUpToDate() throws {
        let text = #"""
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "x",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus[1m]",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "sonnet[1m]",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku[1m]",
            "CLAUDE_CODE_AUTO_MODE_MODEL": "haiku[1m]",
            "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "local"
          },
          "modelSettings": {
            "opus": {"autoCompactWindow": 1000000},
            "sonnet": {"autoCompactWindow": 1000000},
            "haiku": {"autoCompactWindow": 1000000},
            "local": {"autoCompactWindow": 262144}
          }
        }
        """#
        let result = try review(text)
        #expect(result.state == .upToDate)
        #expect(result.changes.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.rows.allSatisfy { !$0.differs })
    }

    @Test func aDifferentFileIsFlaggedRowByRow() throws {
        let text = #"""
        {
          "env": {
            "ANTHROPIC_API_KEY": "x",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.4[1m]",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "2000000"
          },
          "modelSettings": {
            "opus": {"autoCompactWindow": 400000}
          }
        }
        """#
        let result = try review(text)
        #expect(result.state == .differs)
        let byID = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.id, $0) })
        #expect(byID["env.ANTHROPIC_DEFAULT_OPUS_MODEL"]?.recommended == "opus[1m]")
        #expect(byID["env.ANTHROPIC_DEFAULT_OPUS_MODEL"]?.current == "glm-5.4[1m]")
        #expect(byID["env.ANTHROPIC_DEFAULT_OPUS_MODEL"]?.differs == true)
        #expect(byID["env.ANTHROPIC_BASE_URL"]?.differs == false)
        #expect(byID["env.ANTHROPIC_DEFAULT_SONNET_MODEL"]?.current == "not set")
        // Above the local model's window: lowered to it.
        #expect(byID["env.CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.recommended == "262144")
        #expect(byID["env.CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.differs == true)
        #expect(byID["modelSettings.opus.autoCompactWindow"]?.current == "400,000")
        #expect(byID["modelSettings.opus.autoCompactWindow"]?.recommended == "1,000,000")
        #expect(result.warnings.isEmpty, "a sign-in is present and nothing switches compaction off")
    }

    @Test func eachIDShowsItsWindowAndWhereCompactionRuns() throws {
        let result = try review("{}")
        #expect(result.ids.map(\.modelID) == ["opus[1m]", "sonnet[1m]", "haiku[1m]", "local"])
        let local = try #require(result.ids.last)
        #expect(local.window == 262_144)
        #expect(local.threshold == 169_500)
        #expect(local.source == .splash)
        #expect(local.target == "local/qwen3.8-27b-q8 @ splash (local)")
        #expect(result.ids.first?.threshold == 686_000)
    }

    @Test func aMissingFilePlansEverythingAndSaysSo() throws {
        let result = try review(nil)
        #expect(result.state == .noSettingsFile)
        #expect(result.changes.count == 13)
        #expect(result.rows.first?.current == "not set")
    }

    @Test func anUnreadableFileIsNeverPlanned() throws {
        let result = ClaudeSetupReviewer.review(document: nil, readError: .invalidJSON("line 3, column 5: x"),
                                                recommendation: Self.recommended, targets: Self.targets)
        #expect(result.state == .unreadable("line 3, column 5: x"))
        #expect(result.changes.isEmpty)
        #expect(result.rows.isEmpty)
    }

    @Test func whatMustNeverBeWrittenIsNamed() throws {
        let text = #"""
        {
          "autoCompactEnabled": false,
          "env": {
            "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1",
            "DISABLE_COMPACT": "true"
          }
        }
        """#
        let result = try review(text)
        #expect(result.warnings.contains { $0.contains("no sign-in") })
        #expect(result.warnings.contains { $0.contains("CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT") })
        #expect(result.warnings.contains { $0.contains("DISABLE_COMPACT") })
        #expect(result.warnings.contains { $0.contains("autoCompactEnabled") })
        #expect(!result.changes.contains { $0.path.contains("DISABLE_COMPACT") || $0.path == ["autoCompactEnabled"] })
    }

    @Test func switchingOffOneMContextIsCalledOut() throws {
        // With it on, [1m] is ignored and every model is held to a 200K window.
        let text = #"{"env": {"CLAUDE_CODE_DISABLE_1M_CONTEXT": "1", "ANTHROPIC_AUTH_TOKEN": "x"}}"#
        #expect(try review(text).warnings.contains { $0.contains("CLAUDE_CODE_DISABLE_1M_CONTEXT") })
        let off = #"{"env": {"CLAUDE_CODE_DISABLE_1M_CONTEXT": "0", "ANTHROPIC_AUTH_TOKEN": "x"}}"#
        #expect(try !review(off).warnings.contains { $0.contains("CLAUDE_CODE_DISABLE_1M_CONTEXT") })
    }

    @Test func aLocalIDWithoutItsRuleIsCalledOut() throws {
        let result = ClaudeSetupReviewer.review(document: .object(members: []), readError: nil,
                                                recommendation: Self.recommended, targets: [:])
        #expect(result.warnings.contains { $0.contains("local") && $0.contains("catch-all") })
    }
}
