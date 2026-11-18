import Foundation

enum AppPaths {
    static let appSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("ZGate", isDirectory: true)
    }()

    /// The upstream-era directory (2026-11-18 and earlier). Kept only for
    /// the one-time move below — nothing reads it after that.
    static let legacyAppSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("ModelProxy", isDirectory: true)
    }()

    /// One-time directory rename (2026-11-18): upstream's "ModelProxy"
    /// support dir becomes "ZGate". Moves the whole dir (config, logs,
    /// stats, lineages, credentials cache, splash bin) when the legacy dir
    /// exists and the new one doesn't. If both exist the NEW one wins (the
    /// legacy dir is left untouched for manual inspection). Rollback to a
    /// pre-rename app re-seeds defaults — the emergency path accepts that.
    static func migrateLegacyDirIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyAppSupport.path),
              !fm.fileExists(atPath: appSupport.path) else { return }
        do {
            try fm.createDirectory(
                at: appSupport.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacyAppSupport, to: appSupport)
        } catch {
            // Never block launch: fall back to a fresh ZGate dir. NSLog
            // because AppLog setup ordering isn't guaranteed this early.
            NSLog("[ZGate] AppPaths: legacy dir move failed (\(error)) — starting fresh at %@", appSupport.path)
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
    }
}
