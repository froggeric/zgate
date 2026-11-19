import Foundation

/// Disk-side storage operations (spec §3.6): clear the prefix cache, move
/// the HF model cache. Process work goes through injectable `run`/`capture`
/// seams (tests lie about `du` output); `now` pins backup-name timestamps.
/// All statics are pure / FileManager-only so any isolation can call them.
nonisolated struct StorageActions: Sendable {
    enum ActionError: LocalizedError, Equatable {
        case sourceMissing(String)
        case targetNotEmpty(String)
        case preflightSpace
        case verificationFailed
        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "Nothing to move — \(p) does not exist."
            case .targetNotEmpty(let p): return "Target already has content — pick an empty location (\(p))."
            case .preflightSpace: return "Not enough free space at the target for the cache."
            case .verificationFailed: return "Copy verification failed — nothing was changed."
            }
        }
    }

    private enum ProcessError: Error { case failed(Int32) }

    var run: @Sendable ([String]) async throws -> Void
    var capture: @Sendable ([String]) async throws -> String
    var now: @Sendable () -> Date

    init(
        run: @escaping @Sendable ([String]) async throws -> Void = { argv in
            _ = try await StorageActions.runProcess(argv, reading: false)
        },
        capture: @escaping @Sendable ([String]) async throws -> String = { argv in
            try await StorageActions.runProcess(argv, reading: true)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = run
        self.capture = capture
        self.now = now
    }

    /// argv[0] is the executable (the `SplashInstaller.runBrew` shape);
    /// detached so the main actor never blocks on the child.
    private static func runProcess(_ argv: [String], reading: Bool) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            // Drain to EOF BEFORE waitUntilExit — a full pipe would
            // deadlock the child (same reason AppUpdateService reads first).
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw ProcessError.failed(p.terminationStatus) }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    // MARK: Pure facts

    /// Splash counts ONLY 32-hex-digit dirs as caches (spec §2) — the same
    /// shape its own GC removes, so it is exactly what we may wipe.
    /// ASCII hex only: `Character.isHexDigit` alone also accepts fullwidth
    /// forms, which no real namespace dir name carries.
    static func isNamespaceDir(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// HF download cache when `modelCacheLocation` is unset (spec §2).
    static var defaultHFCache: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub", isDirectory: true)
    }

    /// Splash's prefix-cache root when `--persistent-cache` is on with no
    /// `--cache-dir` (spec §2). Without persistent the cache lives in
    /// $TMPDIR and ignores --cache-dir — nothing sensible to clear.
    static var defaultPrefixCache: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/Splash/prefix-cache", isDirectory: true)
    }

    // MARK: Clear prefix cache

    /// Wipes ONLY 32-hex namespace dirs under the prefix-cache root —
    /// splash's own GC shape (spec §2: safe to wipe while stopped). Files
    /// and other dirs survive; a missing root throws (caller shows it).
    static func clearPrefixCache(root: URL) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: root.path)   // throws when root missing
        for n in names where isNamespaceDir(n) {
            try fm.removeItem(at: root.appendingPathComponent(n, isDirectory: true))
        }
    }

    // MARK: Move model cache

    /// ditto copy → size verify → rename source to `<src>.zgate-moved-<ts>`
    /// → return the backup URL. Never auto-deletes — the UI offers
    /// "Delete old location" as a separate explicit action. Any failure
    /// (missing source, non-empty target, low space, failed verify) throws
    /// with the source — and the target — left as they were.
    func moveModelCache(from source: URL, to target: URL) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ActionError.sourceMissing(source.path)
        }
        // ditto MERGES into an existing dir — refuse a non-empty target so
        // the destination is exactly the moved cache, never a mix.
        if fm.fileExists(atPath: target.path),
           let existing = try? fm.contentsOfDirectory(atPath: target.path), !existing.isEmpty {
            throw ActionError.targetNotEmpty(target.path)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        func kb(_ s: String) -> Int { Int(s.split(separator: "\t").first ?? "") ?? -1 }
        let srcKB = kb(try await capture(["/usr/bin/du", "-sk", source.path]))
        guard srcKB > 0 else { throw ActionError.verificationFailed }

        // Preflight (spec §3.6): don't ditto gigabytes onto a volume that
        // can't hold them. Important-usage capacity matches AppUpdateService.
        if let values = try? target.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           free < Int64(srcKB) * 1024 {
            throw ActionError.preflightSpace
        }

        // Copy → verify inside ONE do/catch (fix round 1): any failure after
        // the copy began — ditto dying mid-copy (ENOSPC despite preflight,
        // read error), the post-copy `du` failing, or the size mismatch —
        // removes the target before rethrowing. A lingering partial would
        // block a retry to the same location via the non-empty guard above.
        // The source is untouched in every branch.
        do {
            try await run(["/usr/bin/ditto", source.path, target.path])
            let dstKB = kb(try await capture(["/usr/bin/du", "-sk", target.path]))
            guard dstKB >= srcKB else { throw ActionError.verificationFailed }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }

        let ts = Int(now().timeIntervalSince1970)
        let backup = source.deletingLastPathComponent()
            .appendingPathComponent("\(source.lastPathComponent).zgate-moved-\(ts)")
        try? fm.removeItem(at: backup)   // same-second collision: replace
        try fm.moveItem(at: source, to: backup)
        return backup
    }
}
