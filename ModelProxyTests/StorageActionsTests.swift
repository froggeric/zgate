import Foundation
import Testing
@testable import ZGate

/// Disk-side storage mechanics (spec §3.6) on REAL temp dirs — ditto, du
/// and tar are local tools; no network, no process spawn beyond those.
@Suite struct StorageActionsTests {

    // MARK: namespace rule

    @Test func namespaceDirRule() {
        #expect(StorageActions.isNamespaceDir("0123456789abcdef0123456789abcdef"))
        #expect(StorageActions.isNamespaceDir("0123456789ABCDEF0123456789ABCDEF"))
        #expect(!StorageActions.isNamespaceDir("0123456789abcdef0123456789abcde"))   // 31
        #expect(!StorageActions.isNamespaceDir("0123456789abcdef0123456789abcdeff"))   // 33
        #expect(!StorageActions.isNamespaceDir("zzzz456789abcdef0123456789abcde".replacingOccurrences(of: "z", with: "f") + " extra"))   // non-hex / spaces
        #expect(!StorageActions.isNamespaceDir(""))
    }

    // MARK: clear prefix cache

    @Test func clearRemovesOnlyNamespaces() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("prefix-\(UUID().uuidString)", isDirectory: true)
        let ns = root.appendingPathComponent("0123456789abcdef0123456789abcdef", isDirectory: true)
        let keepDir = root.appendingPathComponent("keep", isDirectory: true)
        try fm.createDirectory(at: ns, withIntermediateDirectories: true)
        try fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ns.appendingPathComponent("blob"))
        try Data("x".utf8).write(to: keepDir.appendingPathComponent("blob"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))

        try StorageActions.clearPrefixCache(root: root)

        #expect(!fm.fileExists(atPath: ns.path))   // the namespace dir is gone
        #expect(fm.fileExists(atPath: keepDir.appendingPathComponent("blob").path))   // other dirs survive
        #expect(fm.fileExists(atPath: root.appendingPathComponent("notes.txt").path))   // files survive
    }

    @Test func clearThrowsWhenRootMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-root-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: (any Error).self) {
            try StorageActions.clearPrefixCache(root: missing)
        }
    }

    // MARK: move model cache

    /// 1 MB of real bytes so `du -sk` reports a size worth verifying.
    /// Lives inside its own dedicated parent so sibling tests' temp
    /// leftovers never leak into ".zgate-moved-" scans.
    private func makeCacheDir(_ name: String) throws -> (parent: URL, dir: URL) {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        let blobs = dir.appendingPathComponent("models--x--y", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: blobs.appendingPathComponent("model.bin"))
        return (parent, dir)
    }

    @Test func moveCopiesVerifiesAndBacksUp() async throws {
        let fm = FileManager.default
        let (srcParent, src) = try makeCacheDir("hub")
        let dstParent = fm.temporaryDirectory
            .appendingPathComponent("dst-\(UUID().uuidString)", isDirectory: true)
        let dst = dstParent.appendingPathComponent("hub", isDirectory: true)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let actions = StorageActions(now: { stamp })   // real ditto/du, pinned ts

        let backup = try await actions.moveModelCache(from: src, to: dst)

        #expect(backup.lastPathComponent == "\(src.lastPathComponent).zgate-moved-1700000000")
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("models--x--y/model.bin").path))   // copy landed
        #expect(!fm.fileExists(atPath: src.path))   // source renamed away
        #expect(fm.fileExists(atPath: backup.appendingPathComponent("models--x--y/model.bin").path))   // backup holds it
        try fm.removeItem(at: dstParent)
        try fm.removeItem(at: srcParent)   // the renamed backup lives here now
    }

    @Test func moveAbortsWhenTargetTooSmallOrMissing() async throws {
        let fm = FileManager.default
        // Real ditto, but `du` lies: dst reports 0 KB → verification fails.
        let (srcParent, src) = try makeCacheDir("hub")
        let dst = fm.temporaryDirectory
            .appendingPathComponent("dst2-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        let actions = StorageActions(
            capture: { argv in
                argv.last == src.path ? "2048\t\(src.path)" : "0\t\(argv.last ?? "")"
            })

        await #expect(throws: (any Error).self) {
            _ = try await actions.moveModelCache(from: src, to: dst)
        }
        // Failure leaves the source untouched: still there, no backup side-by-side,
        // and the failed copy at the target is cleaned up.
        #expect(fm.fileExists(atPath: src.appendingPathComponent("models--x--y/model.bin").path))
        #expect(try fm.contentsOfDirectory(atPath: srcParent.path)
            .filter { $0.contains(".zgate-moved-") } == [])
        #expect(!fm.fileExists(atPath: dst.path))
        try fm.removeItem(at: srcParent)

        // Missing source aborts before anything happens.
        let ghost = fm.temporaryDirectory
            .appendingPathComponent("ghost-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: (any Error).self) {
            _ = try await actions.moveModelCache(from: ghost, to: dst)
        }
    }

    @Test func movePreflightAbortsBeforeCopyingWhenVolumeTooSmall() async throws {
        let fm = FileManager.default
        let (srcParent, src) = try makeCacheDir("hub")
        let dst = fm.temporaryDirectory
            .appendingPathComponent("dst3-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        var dittoRan = false
        let actions = StorageActions(
            run: { _ in dittoRan = true },   // ditto must never run
            // src "measures" ~99 TB — more than any real volume has free.
            capture: { _ in "99999999999\t\(src.path)" })

        await #expect(throws: StorageActions.ActionError.preflightSpace) {
            _ = try await actions.moveModelCache(from: src, to: dst)
        }
        #expect(!dittoRan)
        #expect(fm.fileExists(atPath: src.appendingPathComponent("models--x--y/model.bin").path))
        #expect(!fm.fileExists(atPath: dst.path))
        try fm.removeItem(at: srcParent)
    }

    // Fix round 1: ANY failure after the copy began must clean the target —
    // a lingering partial would block a retry via the non-empty guard.

    @Test func moveCleansPartialTargetWhenDittoDiesMidCopy() async throws {
        let fm = FileManager.default
        let (srcParent, src) = try makeCacheDir("hub")
        let dst = fm.temporaryDirectory
            .appendingPathComponent("dst4-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        struct DiedMidCopy: Error {}
        let actions = StorageActions(
            run: { _ in
                // ditto materialized part of the target, then died.
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: dst.appendingPathComponent("partial.bin"))
                throw DiedMidCopy()
            },
            capture: { _ in "2048\t\(src.path)" })

        await #expect(throws: DiedMidCopy.self) {
            _ = try await actions.moveModelCache(from: src, to: dst)
        }
        #expect(!fm.fileExists(atPath: dst.path))   // partial copy cleaned
        #expect(fm.fileExists(atPath: src.appendingPathComponent("models--x--y/model.bin").path))   // source intact
        try fm.removeItem(at: srcParent)
    }

    @Test func moveCleansTargetWhenPostCopyDuFails() async throws {
        let fm = FileManager.default
        let (srcParent, src) = try makeCacheDir("hub")
        let dst = fm.temporaryDirectory
            .appendingPathComponent("dst5-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        struct DuDied: Error {}
        // Serial call counter: capture #1 answers the source du, #2 (the
        // post-copy target du) dies.
        final class Calls: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        let calls = Calls()
        let actions = StorageActions(
            run: { _ in
                // the "copy" lands (simulated), verification then breaks
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: dst.appendingPathComponent("model.bin"))
            },
            capture: { _ in
                if calls.next() >= 2 { throw DuDied() }
                return "2048\t\(src.path)"
            })

        await #expect(throws: DuDied.self) {
            _ = try await actions.moveModelCache(from: src, to: dst)
        }
        #expect(!fm.fileExists(atPath: dst.path))   // cleaned despite the copy "succeeding"
        #expect(fm.fileExists(atPath: src.appendingPathComponent("models--x--y/model.bin").path))
        try fm.removeItem(at: srcParent)
    }

    @Test func moveRefusesNonEmptyTargetWithoutTouchingSource() async throws {
        let fm = FileManager.default
        let (srcParent, src) = try makeCacheDir("hub")
        let (dstParent, dst) = try makeCacheDir("hub-existing")   // already has content
        let actions = StorageActions()

        await #expect(throws: (any Error).self) {
            _ = try await actions.moveModelCache(from: src, to: dst)
        }
        #expect(fm.fileExists(atPath: src.appendingPathComponent("models--x--y/model.bin").path))   // untouched
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("models--x--y/model.bin").path))   // target untouched too
        try fm.removeItem(at: srcParent)
        try fm.removeItem(at: dstParent)
    }
}
