import Foundation
import Testing
@testable import ZGate

/// The plan from "what the file says" to "what ZGate recommends": which keys
/// change, which are left alone, and what the file looks like afterwards.
@Suite struct ClaudeSetupPlannerTests {

    /// The owner's file as it was on 2026-11-23: `[1m]` ids (proactive
    /// compaction off), a global cap of 262144, saved effort levels.
    private static let today = #"""
    {
      "env": {
        "ANTHROPIC_AUTH_TOKEN": "secret-not-shown",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5.3-flash[1m]",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.4[1m]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.4[1m]",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
      },
      "model": "opus",
      "modelSettings": {
        "glm-5.4": {
          "effortLevel": "max"
        },
        "glm-5.3-flash": {
          "effortLevel": "low",
          "autoCompactWindow": 120000
        }
      },
      "permissions": {
        "allow": [
          "Bash(git status:*)"
        ]
      }
    }
    """#

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

    private func node(_ text: String) throws -> JSONNode {
        try JSONText(parsing: text).root
    }

    /// "set env.ANTHROPIC_BASE_URL" for each change.
    private func summary(_ changes: [ClaudeSettingsChange]) -> [String] {
        changes.map { "\(String(describing: $0.kind)) \($0.label)" }
    }

    @Test func planForTheFileOfToday() throws {
        let changes = ClaudeSetupPlanner.changes(for: try node(Self.today), recommendation: Self.recommended)
        #expect(summary(changes) == [
            "copy modelSettings.glm-5.4",
            "rename modelSettings.glm-5.4",
            "rename modelSettings.glm-5.3-flash",
            "set env.ANTHROPIC_DEFAULT_OPUS_MODEL",
            "set env.ANTHROPIC_DEFAULT_SONNET_MODEL",
            "set env.ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "set env.CLAUDE_CODE_AUTO_MODE_MODEL",
            "set env.CLAUDE_CODE_GATEWAY_HINT_HEADERS",
            "set env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
            "set env.ANTHROPIC_CUSTOM_MODEL_OPTION",
            "set modelSettings.opus.autoCompactWindow",
            "set modelSettings.sonnet.autoCompactWindow",
            "set modelSettings.haiku.autoCompactWindow",
            "set modelSettings.local.autoCompactWindow",
        ])
        // Saved settings move to the key without the suffix — the wire id.
        #expect(changes.first { $0.kind == .rename && $0.path.last == "glm-5.3-flash" }?.destination?.last == "haiku")
        #expect(changes.first { $0.path == ["env", "ANTHROPIC_DEFAULT_OPUS_MODEL"] }?.value == "opus[1m]")
        #expect(changes.first { $0.path == ["modelSettings", "opus", "autoCompactWindow"] }?.value == "1000000")
    }

    @Test func aFileAlreadyOnTheSuffixPlansOnlyWhatIsLeft() throws {
        let text = Self.today
            .replacingOccurrences(of: "\"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"glm-5.4[1m]\"",
                                  with: "\"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"opus[1m]\"")
            .replacingOccurrences(of: "\"glm-5.4\": {",
                                  with: "\"opus\": {\n      \"autoCompactWindow\": 1000000\n    },\n    \"glm-5.4\": {")
        let lines = summary(ClaudeSetupPlanner.changes(for: try node(text), recommendation: Self.recommended))
        #expect(!lines.contains { $0.contains("ANTHROPIC_DEFAULT_OPUS_MODEL") || $0.contains("modelSettings.opus") })
        #expect(lines.contains("set env.ANTHROPIC_DEFAULT_SONNET_MODEL"))
        #expect(lines.contains("set env.ANTHROPIC_DEFAULT_HAIKU_MODEL"))
        #expect(lines.contains("rename modelSettings.glm-5.4"))
    }

    @Test func theFileAfterwards() throws {
        var root = try node(Self.today)
        ClaudeSetupPlanner.apply(
            ClaudeSetupPlanner.changes(for: root, recommendation: Self.recommended), to: &root)
        let expected = #"""
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "secret-not-shown",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku[1m]",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus[1m]",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "sonnet[1m]",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144",
            "CLAUDE_CODE_AUTO_MODE_MODEL": "haiku[1m]",
            "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "local"
          },
          "model": "opus",
          "modelSettings": {
            "opus": {
              "effortLevel": "max",
              "autoCompactWindow": 1000000
            },
            "haiku": {
              "effortLevel": "low",
              "autoCompactWindow": 1000000
            },
            "sonnet": {
              "effortLevel": "max",
              "autoCompactWindow": 1000000
            },
            "local": {
              "autoCompactWindow": 262144
            }
          },
          "permissions": {
            "allow": [
              "Bash(git status:*)"
            ]
          }
        }
        """#
        #expect(try JSONText(root: root, style: .claudeCode).serialized == expected)
    }

    @Test func anUpToDateFilePlansNothing() throws {
        var root = try node(Self.today)
        ClaudeSetupPlanner.apply(
            ClaudeSetupPlanner.changes(for: root, recommendation: Self.recommended), to: &root)
        #expect(ClaudeSetupPlanner.changes(for: root, recommendation: Self.recommended).isEmpty)
    }

    @Test func baseURLIgnoresATrailingSlash() throws {
        let root = try node(Self.today.replacingOccurrences(
            of: "\"http://127.0.0.1:8787\"", with: "\"http://127.0.0.1:8787/\""))
        let changes = ClaudeSetupPlanner.changes(for: root, recommendation: Self.recommended)
        #expect(!summary(changes).contains("set env.ANTHROPIC_BASE_URL"))
    }

    @Test func aMissingCapIsSetToTheLocalModelsWindowAndAPresentOneStays() throws {
        // [1m] ids ignore the cap; `local` and any id typed by hand take it.
        let without = Self.today.replacingOccurrences(of: ",\n    \"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": \"262144\"", with: "")
        let set = ClaudeSetupPlanner.changes(for: try node(without), recommendation: Self.recommended)
            .first { $0.path == ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"] }
        #expect(set?.value == "262144" && set?.previous == nil)
        // 262,144 already is the local model's window.
        #expect(!summary(ClaudeSetupPlanner.changes(for: try node(Self.today), recommendation: Self.recommended))
            .contains { $0.contains("MAX_CONTEXT_TOKENS") })
    }

    @Test(arguments: [("\"2000000\"", true), ("\"200000\"", false), ("\"abc\"", true)])
    func aLowerCapIsKeptAndAHigherOneIsLowered(_ row: (String, Bool)) throws {
        let text = Self.today.replacingOccurrences(of: "\"262144\"", with: row.0)
        let changes = ClaudeSetupPlanner.changes(for: try node(text), recommendation: Self.recommended)
        #expect(changes.contains { $0.path == ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"] } == row.1)
        #expect(!changes.contains { $0.kind == .remove && $0.path.last == "CLAUDE_CODE_MAX_CONTEXT_TOKENS" })
    }

    @Test func withoutTheLocalIDTheCapIsLeftAlone() throws {
        var off = Self.recommended
        off.localIDEnabled = false
        off.windows["local"] = nil
        #expect(!summary(ClaudeSetupPlanner.changes(for: try node(Self.today), recommendation: off))
            .contains { $0.contains("MAX_CONTEXT_TOKENS") })
    }

    @Test func aCapThatCutsABareTierIsRemoved() throws {
        // A tier routed under a million carries no [1m], so the cap applies to it.
        var small = Self.recommended
        small.opusID = "opus"; small.sonnetID = "sonnet"; small.haikuID = "haiku"
        small.localIDEnabled = false
        small.windows = ["opus": .init(tokens: 400_000, source: .defaultWindow),
                         "sonnet": .init(tokens: 400_000, source: .defaultWindow),
                         "haiku": .init(tokens: 400_000, source: .defaultWindow)]
        #expect(summary(ClaudeSetupPlanner.changes(for: try node(Self.today), recommendation: small))
            .contains("remove env.CLAUDE_CODE_MAX_CONTEXT_TOKENS"))
    }

    @Test func localKeysAreManagedOnlyWhileTheLocalIDIsOn() throws {
        var withLocal = Self.today.replacingOccurrences(
            of: "\"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"glm-5.3-flash[1m]\",",
            with: "\"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"haiku\",\n    \"ANTHROPIC_CUSTOM_MODEL_OPTION\": \"local\",")
        withLocal = withLocal.replacingOccurrences(
            of: "\"glm-5.4\": {", with: "\"local\": {\n        \"autoCompactWindow\": 262144\n      },\n      \"opus\": {")
        var off = Self.recommended
        off.localIDEnabled = false
        off.windows["local"] = nil
        let changes = ClaudeSetupPlanner.changes(for: try node(withLocal), recommendation: off)
        #expect(summary(changes).contains("remove env.ANTHROPIC_CUSTOM_MODEL_OPTION"))
        #expect(summary(changes).contains("remove modelSettings.local"))
        #expect(!summary(changes).contains { $0.hasSuffix(".local.autoCompactWindow") })
    }

    @Test func someoneElsesCustomModelOptionIsLeftAlone() throws {
        let text = Self.today.replacingOccurrences(
            of: "\"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"glm-5.3-flash[1m]\",",
            with: "\"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"haiku\",\n    \"ANTHROPIC_CUSTOM_MODEL_OPTION\": \"my-model\",")
        var off = Self.recommended
        off.localIDEnabled = false
        off.windows["local"] = nil
        #expect(text.contains("my-model"))
        let changes = ClaudeSetupPlanner.changes(for: try node(text), recommendation: off)
        #expect(!summary(changes).contains("ANTHROPIC_CUSTOM_MODEL_OPTION"))
    }

    @Test func aRenameIsNotProposedWhenTheNewKeyIsTaken() throws {
        let text = Self.today.replacingOccurrences(
            of: "\"glm-5.4\": {", with: "\"opus\": {\n        \"effortLevel\": \"high\"\n      },\n      \"glm-5.4\": {")
        let changes = ClaudeSetupPlanner.changes(for: try node(text), recommendation: Self.recommended)
        #expect(!changes.contains { $0.kind == .rename && $0.destination?.last == "opus" })
        var after = try node(text)
        ClaudeSetupPlanner.apply(changes, to: &after)
        #expect(after.value(at: ["modelSettings", "opus", "effortLevel"])?.stringValue == "high")
    }

    @Test func anEmptyFileGetsEveryManagedKey() throws {
        let changes = ClaudeSetupPlanner.changes(for: try node("{}"), recommendation: Self.recommended)
        #expect(summary(changes).filter { $0.hasPrefix("set env.") }.count == 9)
        #expect(summary(changes).filter { $0.hasSuffix("autoCompactWindow") }.count == 4)
        #expect(!summary(changes).contains { $0.hasPrefix("remove") || $0.hasPrefix("rename") || $0.hasPrefix("copy") })
    }

    @Test func noChangeTouchesASecret() throws {
        let changes = ClaudeSetupPlanner.changes(for: try node(Self.today), recommendation: Self.recommended)
        #expect(!changes.contains { $0.label.contains("AUTH_TOKEN") })
        #expect(!changes.contains { ($0.value ?? "").contains("secret") })
    }
}
