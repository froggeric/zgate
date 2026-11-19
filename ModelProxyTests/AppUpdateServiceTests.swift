import Foundation
import Testing
@testable import ZGate

/// AppUpdateService behavior (spec §3.5) through the injected seams: a
/// URL-keyed fetch stub (fixture JSON / real zip bytes), a runCapture
/// stub that runs the REAL ditto but fakes codesign TeamIdentifiers, and
/// a swap script seam that records its own argv — the real
/// release-swap.sh is NEVER executed here (its --dry-run verification is
/// Task 12, manual). Serialized: the staging tests share the test-host
/// app-support dir (updates/<tag>).
@MainActor
@Suite(.serialized) struct AppUpdateServiceTests {

    // MARK: - Fixtures

    private var updates: URL {
        AppPaths.appSupport.appendingPathComponent("updates", isDirectory: true)
    }

    private func stagedApp(tag: String) -> URL {
        updates.appendingPathComponent(tag, isDirectory: true)
            .appendingPathComponent("ZGate.app")
    }

    /// `digest: nil` omits the key — the cannot-stage asset shape.
    private func fixture(
        tag: String,
        digest: String? = "sha256:" + String(repeating: "ab", count: 32)
    ) -> Data {
        var asset = #"{"name":"ZGate-\#(tag).zip","browser_download_url":"https://x/ZGate-\#(tag).zip""#
        if let digest { asset += #","digest":"\#(digest)""# }
        asset += "}"
        return Data(#"{"tag_name":"\#(tag)","assets":[\#(asset)]}"#.utf8)
    }

    private func release(tag: String, digest: String?) -> ZGateRelease {
        ZGateRelease(tag_name: tag, assets: [
            ZGateReleaseAsset(
                name: "ZGate-\(tag).zip",
                browser_download_url: URL(string: "https://x/ZGate-\(tag).zip")!,
                digest: digest),
        ])
    }

    /// A REAL zip the way the release ships it: `/usr/bin/ditto -c -k
    /// --keepParent` on a stub ZGate.app, so stage's `-x -k` lands
    /// ZGate.app inside the tag dir. Returns bytes + their sha256 hex.
    private func makeZip(tag: String) throws -> (Data, String) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("zgate-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let contents = base.appendingPathComponent("ZGate.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("stub-info-plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let zip = base.appendingPathComponent("ZGate-\(tag).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent",
                       base.appendingPathComponent("ZGate.app").path, zip.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let data = try Data(contentsOf: zip)
        try? fm.removeItem(at: base)
        return (data, SHA256Hex.of(data))
    }

    /// URL-keyed fetch stub (the UpdateCenterTests idiom); an unserved
    /// URL throws. Lock-guarded: the fetch seam is @Sendable.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private var fixtures: [URL: Data] = [:]
        func serve(_ data: Data, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            fixtures[url] = data
        }
        func fetch(_ url: URL) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = fixtures[url] else {
                throw URLError(.notConnectedToInternet)
            }
            return data
        }
    }

    /// Lock-guarded append-only list (recordings from @Sendable seams).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) {
            lock.lock(); defer { lock.unlock() }
            items.append(item)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    // MARK: - Service factory

    /// codesign legs answer by path (staged lives under …/updates/, the
    /// running bundle anywhere else); every other argv — ditto — runs for
    /// real through the production capture helper.
    private func makeService(
        stub: FetchStub,
        currentBundlePath: String = AppUpdateService.prodAppPath,
        teamStaged: String? = "TEAM12345",
        teamCurrent: String? = "TEAM12345",
        codesignPaths: Recorder? = nil,
        scriptPath: URL? = nil
    ) -> AppUpdateService {
        AppUpdateService(deps: AppUpdateService.Deps(
            fetch: { try stub.fetch($0) },
            runCapture: { argv in
                if argv.first == "/usr/bin/codesign" {
                    let path = argv[2]
                    codesignPaths?.add(path)
                    let team = path.contains("/updates/") ? teamStaged : teamCurrent
                    return team.map { "Executable=\(path)\nTeamIdentifier=\($0)\n" }
                        ?? "Executable=\(path)\n"
                }
                return try await AppUpdateService.runCaptureProcess(argv)
            },
            currentBundlePath: { currentBundlePath },
            scriptPath: { scriptPath }))
    }

    // MARK: - Version sanity (full ZGateVersion suite: UpdateCenterTests)

    @Test func tagParseAndCompare() {
        #expect(ZGateVersion.parse(tag: "v2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "junk") == nil)
        #expect(ZGateVersion.isNewer((2, 9, 0), than: (2, 8, 9)))
        #expect(!ZGateVersion.isNewer((2, 8, 9), than: (2, 8, 9)))
    }

    // MARK: - Check

    @Test func missingDigestCannotStage() async throws {
        let stub = FetchStub()
        stub.serve(fixture(tag: "v2.9.0", digest: nil), for: AppUpdateService.releasesURL)
        let service = makeService(stub: stub)
        // latestRelease filters digest-less assets out (honest degrade).
        #expect(await service.latestRelease() == nil)
        // And stage refuses such a release outright — before any fetch.
        await #expect(throws: AppUpdateService.StageError.staging("digest")) {
            _ = try await service.stage(release(tag: "v2.9.0", digest: nil))
        }
    }

    @Test func checkStateMapsFetchToStates() async {
        let stub = FetchStub()
        stub.serve(fixture(tag: "v2.9.0"), for: AppUpdateService.releasesURL)
        let service = makeService(stub: stub)
        await #expect(service.checkState(current: (2, 8, 9))
            == .available(tag: "v2.9.0", current: "2.8.9"))
        await #expect(service.checkState(current: (2, 9, 0)) == .upToDate)

        stub.serve(Data("{}".utf8), for: AppUpdateService.releasesURL)  // undecodable
        await #expect(service.checkState(current: (2, 8, 9)) == .cannotCheck)
    }

    // MARK: - Stage

    @Test func digestMismatchAbortsStaging() async throws {
        let (zip, hex) = try makeZip(tag: "v2.9.0")
        let stub = FetchStub()
        stub.serve(zip, for: URL(string: "https://x/ZGate-v2.9.0.zip")!)
        let service = makeService(stub: stub)
        let bad = "sha256:dead" + String(hex.dropFirst(6))
        await #expect(throws: AppUpdateService.StageError.checksumMismatch) {
            _ = try await service.stage(release(tag: "v2.9.0", digest: bad))
        }
        // Aborted before anything touched disk: no tag dir, no temp zip.
        #expect(!FileManager.default.fileExists(
            atPath: updates.appendingPathComponent("v2.9.0").path))
        #expect(!FileManager.default.fileExists(atPath: updates.path))
    }

    @Test func stagingUnpacksAndVerifiesTeamID() async throws {
        let (zip, hex) = try makeZip(tag: "v2.9.0")
        let stub = FetchStub()
        stub.serve(zip, for: URL(string: "https://x/ZGate-v2.9.0.zip")!)
        let codesigns = Recorder()
        let service = makeService(stub: stub, codesignPaths: codesigns)
        let staged = try await service.stage(release(tag: "v2.9.0", digest: "sha256:\(hex)"))
        #expect(staged == stagedApp(tag: "v2.9.0"))
        #expect(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("Contents/Info.plist").path))
        // Identity check beside the sha256: codesign ran on BOTH bundles.
        #expect(codesigns.all == [staged.path, AppUpdateService.prodAppPath])
    }

    @Test func teamIDMismatchThrows() async throws {
        let (zip, hex) = try makeZip(tag: "v2.9.0")
        let stub = FetchStub()
        stub.serve(zip, for: URL(string: "https://x/ZGate-v2.9.0.zip")!)
        let service = makeService(stub: stub, teamStaged: "TEAMB", teamCurrent: "TEAMA")
        await #expect(throws: AppUpdateService.StageError.teamMismatch("TEAMA")) {
            _ = try await service.stage(release(tag: "v2.9.0", digest: "sha256:\(hex)"))
        }
    }

    // MARK: - Swap

    @Test func swapRefusesNonApplicationsInstall() async throws {
        let stub = FetchStub()
        let service = makeService(
            stub: stub, currentBundlePath: "/Volumes/ssd/builds/ZGate.app")
        await #expect(throws: AppUpdateService.StageError.notProdInstall) {
            try await service.swap(staged: stagedApp(tag: "v2.9.0"))
        }
    }

    @Test func swapMissingScriptThrows() async throws {
        let stub = FetchStub()
        let service = makeService(stub: stub)  // scriptPath seam → nil
        await #expect(throws: AppUpdateService.StageError.missingScript) {
            try await service.swap(staged: stagedApp(tag: "v2.9.0"))
        }
    }

    /// The script seam is a stub that records its own comm (must be zsh),
    /// $0 (the script) and $1 (the staged path), then sleeps 5 s — swap()
    /// must return BEFORE that sleep ends (detached, never awaited).
    @Test func swapInvokesScriptDetachedWithStagedPath() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("zgate-swap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stub-swap.sh")
        let recorder = dir.appendingPathComponent("argv.txt")
        try Data("""
        #!/bin/zsh
        print -r -- "$(ps -o comm= -p $$)" >> '\(recorder.path)'
        print -r -- "$0" >> '\(recorder.path)'
        print -r -- "$1" >> '\(recorder.path)'
        sleep 5

        """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? fm.removeItem(at: dir) }

        let stub = FetchStub()
        let service = makeService(stub: stub, scriptPath: script)
        let staged = stagedApp(tag: "v2.9.0")
        let started = Date()
        try await service.swap(staged: staged)
        let elapsed = Date().timeIntervalSince(started)

        var lines: [String] = []
        for _ in 0..<100 {   // ≤10 s for the detached process to record
            if let data = try? Data(contentsOf: recorder),
               let text = String(data: data, encoding: .utf8) {
                lines = text.split(separator: "\n").map(String.init)
                if lines.count >= 3 { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(lines.count >= 3)
        #expect(lines[0].contains("zsh"))   // interpreter: /bin/zsh
        #expect(lines[1] == script.path)    // argv[1]: the script
        #expect(lines[2] == staged.path)    // argv[2]: the staged app
        #expect(elapsed < 2)                // back before the 5 s sleep → not awaited
    }
}
