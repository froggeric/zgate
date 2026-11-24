import Foundation
import Testing
@testable import ZGate

/// The one place that writes `~/.claude/settings.json`. The file holds
/// secrets and settings that are nobody else's business, so a write must be
/// previewed, backed up, and refused when anything is not as it was.
@Suite struct ClaudeSettingsFileStoreTests {

    private let fm = FileManager.default

    private static let fixture = #"""
    {
      "env": {
        "ANTHROPIC_AUTH_TOKEN": "secret-not-shown",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.4[1m]",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
      },
      "modelSettings": {
        "glm-5.4": {
          "effortLevel": "max"
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
        opusID: "opus[1m]", sonnetID: "sonnet[1m]", haikuID: "haiku[1m]", localIDEnabled: false,
        compactPercent: 70,
        windows: [
            "opus[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
            "sonnet[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
            "haiku[1m]": .init(tokens: 1_000_000, source: .defaultWindow),
        ])

    private func makeStore(file: String? = Self.fixture, mode: Int = 0o644) throws
        -> (store: ClaudeSettingsFileStore, url: URL) {
        let dir = fm.temporaryDirectory.appendingPathComponent("zgate-claude-setup-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let file {
            try Data(file.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        return (ClaudeSettingsFileStore(fileURL: url), url)
    }

    private func remove(_ url: URL) {
        try? fm.removeItem(at: url.deletingLastPathComponent())
    }

    private func mode(of url: URL) throws -> Int {
        try fm.attributesOfItem(atPath: url.path)[.posixPermissions].map { ($0 as! NSNumber).intValue } ?? -1
    }

    private func plan(_ store: ClaudeSettingsFileStore) throws -> (snapshot: ClaudeSettingsFileStore.Snapshot,
                                                                   changes: [ClaudeSettingsChange]) {
        let snapshot = try store.read()
        return (snapshot, ClaudeSetupPlanner.changes(for: snapshot.root, recommendation: Self.recommended))
    }

    @Test func readReportsAMissingFile() throws {
        let (store, url) = try makeStore(file: nil)
        defer { remove(url) }
        #expect(throws: ClaudeSettingsFileStore.ReadError.missing) { try store.read() }
    }

    @Test func readReportsInvalidJSONWithItsPosition() throws {
        let (store, url) = try makeStore(file: "{oops")
        defer { remove(url) }
        do {
            _ = try store.read()
            Issue.record("accepted invalid JSON")
        } catch ClaudeSettingsFileStore.ReadError.invalidJSON(let reason) {
            #expect(reason.contains("line 1"))
        }
    }

    @Test func readRefusesAFileWhoseSectionsAreNotObjects() throws {
        let (store, url) = try makeStore(file: #"{"env": "x"}"#)
        defer { remove(url) }
        do {
            _ = try store.read()
            Issue.record("accepted a file with env as a string")
        } catch ClaudeSettingsFileStore.ReadError.invalidJSON {
            // expected
        }
    }

    @Test func applyWritesThePlanAndKeepsABackup() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        let (snapshot, changes) = try plan(store)
        let backupName = try store.apply(changes, expecting: snapshot.fingerprint)
        let written = try JSONText(parsing: Data(contentsOf: url))
        #expect(written.serialized.contains("\"ANTHROPIC_AUTH_TOKEN\": \"secret-not-shown\""))
        #expect(written.root.value(at: ["env", "ANTHROPIC_DEFAULT_OPUS_MODEL"])?.stringValue == "opus[1m]")
        #expect(written.root.value(at: ["modelSettings", "opus", "effortLevel"])?.stringValue == "max")
        #expect(written.root.value(at: ["modelSettings", "opus", "autoCompactWindow"])?.intValue == 1_000_000)
        // No local id in this recommendation: the cap is not managed and stays.
        #expect(written.root.value(at: ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])?.text == "262144")
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backupName ?? ""))
            == Data(Self.fixture.utf8))
    }

    @Test func applyRefusesAFileThatChangedSinceThePreview() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        let (snapshot, changes) = try plan(store)
        let external = Self.fixture + "\n"
        try Data(external.utf8).write(to: url)
        #expect(throws: ClaudeSettingsFileStore.WriteError.changedSincePreview) {
            try store.apply(changes, expecting: snapshot.fingerprint)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
        #expect(store.backups().isEmpty)
    }

    @Test func aSecondApplyWritesNothing() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        let (snapshot, changes) = try plan(store)
        _ = try store.apply(changes, expecting: snapshot.fingerprint)
        let (after, again) = try plan(store)
        #expect(again.isEmpty)
        #expect(try store.apply(again, expecting: after.fingerprint) == nil)
        #expect(store.backups().count == 1)
    }

    @Test func applyCreatesAMissingFileWithMode0600() throws {
        let (store, url) = try makeStore(file: nil)
        defer { remove(url) }
        let changes = ClaudeSetupPlanner.changes(for: .object(members: []), recommendation: Self.recommended)
        _ = try store.apply(changes, expecting: nil)
        #expect(try mode(of: url) == 0o600)
        let written = try JSONText(parsing: Data(contentsOf: url))
        #expect(written.root.value(at: ["env", "ANTHROPIC_BASE_URL"])?.stringValue == "http://127.0.0.1:8787")
        #expect(store.backups().isEmpty)
    }

    @Test func aMissingFileThatAppearedSinceThePreviewIsNotOverwritten() throws {
        let (store, url) = try makeStore(file: nil)
        defer { remove(url) }
        try Data("{\"a\": 1}".utf8).write(to: url)
        let changes = ClaudeSetupPlanner.changes(for: .object(members: []), recommendation: Self.recommended)
        #expect(throws: ClaudeSettingsFileStore.WriteError.changedSincePreview) {
            try store.apply(changes, expecting: nil)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"a\": 1}")
    }

    @Test func applyKeepsTheOriginalPermissions() throws {
        let (store, url) = try makeStore(mode: 0o640)
        defer { remove(url) }
        let (snapshot, changes) = try plan(store)
        _ = try store.apply(changes, expecting: snapshot.fingerprint)
        #expect(try mode(of: url) == 0o640)
    }

    @Test func restorePutsThePreviousFileBack() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        let (snapshot, changes) = try plan(store)
        _ = try store.apply(changes, expecting: snapshot.fingerprint)
        let backup = try #require(store.backups().first)
        let current = try store.read()
        _ = try store.restore(backup, expecting: current.fingerprint)
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.fixture)
        #expect(store.backups().count == 2)
        #expect(try !plan(store).changes.isEmpty)
    }

    @Test func restoreRefusesABackupThatIsNotJSON() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        let bogus = url.deletingLastPathComponent()
            .appendingPathComponent(ClaudeSettingsFileStore.backupPrefix + "20260101-000000")
        try Data("{oops".utf8).write(to: bogus)
        let current = try store.read()
        #expect(throws: (any Error).self) { try store.restore(bogus, expecting: current.fingerprint) }
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.fixture)
    }

    @Test func oldBackupsArePrunedToTen() throws {
        let (store, url) = try makeStore()
        defer { remove(url) }
        for minute in 1...12 {
            let old = url.deletingLastPathComponent().appendingPathComponent(
                String(format: "%@20260101-00%02d00", ClaudeSettingsFileStore.backupPrefix, minute))
            try Data("{}".utf8).write(to: old)
        }
        let (snapshot, changes) = try plan(store)
        let newest = try store.apply(changes, expecting: snapshot.fingerprint)
        let names = store.backups().map(\.lastPathComponent)
        #expect(names.count == 10)
        #expect(names.first == newest)
        #expect(names.last == ClaudeSettingsFileStore.backupPrefix + "20260101-000400")
    }

    @Test func theDefaultLocationFollowsCLAUDE_CONFIG_DIR() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(ClaudeSettingsFileStore.defaultFileURL(configDir: nil) == home.appendingPathComponent(".claude/settings.json"))
        let custom = home.appendingPathComponent("elsewhere")
        #expect(ClaudeSettingsFileStore.defaultFileURL(configDir: custom) == custom.appendingPathComponent("settings.json"))
    }
}
