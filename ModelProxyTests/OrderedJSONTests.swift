import Foundation
import Testing
@testable import ZGate

/// The ordered JSON document behind the Claude Code settings configurator.
/// `settings.json` holds keys that are nobody else's business, so a write
/// must change the managed keys and reproduce every other byte: member
/// order, indentation, the spelling of numbers and string escapes.
@Suite struct OrderedJSONTests {

    /// Shaped like a real Claude Code `settings.json`: nested objects, an
    /// array, empty containers, booleans, ints, a float, non-ASCII and an
    /// escape, and no trailing newline (how Claude Code writes the file).
    private static let fixture = #"""
    {
      "env": {
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.4[1m]",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS": 262144
      },
      "permissions": {
        "allow": [
          "Bash(git status:*)",
          "Bash(git diff:*)"
        ],
        "deny": [],
        "defaultMode": "acceptEdits"
      },
      "model": "opus",
      "effortLevel": "high",
      "maxEffortLevel": true,
      "modelSettings": {
        "glm-5.4[1m]": {
          "effortLevel": "high",
          "autoCompactWindow": 120000.50
        },
        "haiku": {}
      },
      "statusLine": {
        "note": "café — prêt é"
      }
    }
    """#

    private func serialized(_ text: String, _ edit: (inout JSONNode) -> Void) throws -> String {
        var doc = try JSONText(parsing: text)
        edit(&doc.root)
        return doc.serialized
    }

    private func reindent(_ text: String, unit: String, newline: String = "\n") -> String {
        text.components(separatedBy: "\n").map { line in
            let spaces = line.prefix { $0 == " " }.count
            return String(repeating: unit, count: spaces / 2) + line.dropFirst(spaces)
        }.joined(separator: newline)
    }

    @Test func roundTripIsByteIdentical() throws {
        let doc = try JSONText(parsing: Self.fixture)
        #expect(doc.serialized == Self.fixture)
    }

    @Test(arguments: ["    ", "\t"])
    func roundTripKeepsIndentUnit(_ unit: String) throws {
        let text = reindent(Self.fixture, unit: unit)
        let doc = try JSONText(parsing: text)
        #expect(doc.serialized == text)
    }

    @Test func roundTripKeepsCRLF() throws {
        let text = reindent(Self.fixture, unit: "  ", newline: "\r\n")
        let doc = try JSONText(parsing: text)
        #expect(doc.serialized == text)
    }

    @Test func roundTripKeepsTrailingNewlineAndOneLineDocuments() throws {
        for text in ["{\"a\": 1}", Self.fixture + "\n", "{\n  \"a\": \"x\"\n}\n"] {
            let doc = try JSONText(parsing: text)
            #expect(doc.serialized == text)
        }
    }

    @Test func replacingAValueChangesOnlyThatValue() throws {
        let out = try serialized(Self.fixture) { root in
            root.set(.string("opus"), at: ["env", "ANTHROPIC_DEFAULT_OPUS_MODEL"])
        }
        #expect(out == Self.fixture.replacingOccurrences(
            of: "\"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"glm-5.4[1m]\"",
            with: "\"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"opus\""))
    }

    @Test func addingAMemberAppendsItWithTheDocumentsStyle() throws {
        let out = try serialized(Self.fixture) { root in
            root.set(.string("70"), at: ["env", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"])
        }
        #expect(out == Self.fixture.replacingOccurrences(
            of: "\"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": 262144\n",
            with: "\"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": 262144,\n    \"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"70\"\n"))
    }

    @Test func removingAMemberRemovesItsCommaAndLine() throws {
        let out = try serialized(Self.fixture) { root in
            root.remove(at: ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        }
        #expect(out == Self.fixture.replacingOccurrences(
            of: ",\n    \"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": 262144",
            with: ""))
    }

    @Test func settingCreatesMissingObjects() throws {
        let out = try serialized("{\"a\": 1, \"b\": [1, 2]}") { root in
            root.set(.number("1000000"), at: ["modelSettings", "opus", "autoCompactWindow"])
        }
        #expect(out == "{\"a\": 1, \"b\": [1, 2], \"modelSettings\": {\"opus\": {\"autoCompactWindow\": 1000000}}}")
    }

    @Test func aNewDocumentLooksLikeClaudeCodeWritesIt() throws {
        var doc = JSONText.empty()
        doc.root.set(.string("v"), at: ["k"])
        #expect(doc.serialized == "{\n  \"k\": \"v\"\n}")
        var existing = try JSONText(parsing: "{}")
        existing.root.set(.number("5"), at: ["k"])
        #expect(existing.serialized == "{\n  \"k\": 5\n}")
    }

    @Test func removingTheLastMemberOfAnObjectRemovesTheObject() throws {
        let out = try serialized("{\"env\": {\"A\": \"1\"}, \"x\": 1}") { root in
            root.remove(at: ["env", "A"])
        }
        #expect(out == "{\"x\": 1}")
    }

    @Test func renamingAKeyKeepsItsPositionAndValue() throws {
        let out = try serialized(Self.fixture) { root in
            root.renameMember(ofObjectAt: ["modelSettings"], from: "glm-5.4[1m]", to: "opus")
        }
        #expect(out == Self.fixture.replacingOccurrences(
            of: "\"glm-5.4[1m]\": {", with: "\"opus\": {"))
    }

    @Test func numbersKeepTheirSpelling() throws {
        let text = #"{"a": 1.0, "b": 1e5, "c": -0, "d": 1E+2, "e": 120000.50}"#
        let doc = try JSONText(parsing: text)
        #expect(doc.serialized == text)
        #expect(doc.root.value(at: ["c"])?.intValue == 0)
        #expect(doc.root.value(at: ["a"])?.intValue == nil)
    }

    @Test func stringsKeepTheirEscapesAndDecode() throws {
        let text = #"{"a": "café ✓", "b": "x\/y", "c": "line\nbreak"}"#
        let doc = try JSONText(parsing: text)
        #expect(doc.serialized == text)
        #expect(doc.root.value(at: ["a"])?.stringValue == "café ✓")
        #expect(doc.root.value(at: ["c"])?.stringValue == "line\nbreak")
    }

    @Test func readsNestedValues() throws {
        let doc = try JSONText(parsing: Self.fixture)
        #expect(doc.root.value(at: ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])?.intValue == 262144)
        #expect(doc.root.value(at: ["modelSettings", "haiku"])?.objectMembers?.isEmpty == true)
        #expect(doc.root.value(at: ["permissions", "allow"])?.arrayElements?.count == 2)
        #expect(doc.root.value(at: ["missing", "key"]) == nil)
        #expect(doc.root.value(at: ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])?.stringValue == nil)
    }

    @Test func invalidJSONNamesItsPosition() throws {
        let bad: [(String, String)] = [
            ("{\"a\": }", "line 1, column 7"),
            ("{\"a\": 1} x", "line 1, column 10"),
            ("{\n  \"a\": \"x", "line 2, column 8"),
            ("{\"a\": 1,", "line 1, column 9"),
            ("{\"a\": \"x\ty\"}", "line 1, column 9"),
            ("{\"a\": 01}", "line 1, column 8"),
            ("{\"a\": 1, \"a\": 2}", "duplicate"),
        ]
        for (text, expected) in bad {
            let result = Result { try JSONText(parsing: text) }
            guard case .failure(let error) = result else {
                Issue.record("accepted invalid JSON: \(text)")
                continue
            }
            #expect("\(error)".contains(expected), "\(text) -> \(error)")
        }
    }

    @Test func rejectsInvalidUTF8() throws {
        let result = Result { try JSONText(parsing: Data([0x7B, 0x22, 0xFF, 0x7D])) }
        guard case .failure = result else {
            Issue.record("accepted invalid UTF-8")
            return
        }
    }
}
