import Foundation

enum AppPaths {

    /// Per-run temp base active when this process is an xcodebuild test
    /// host outside E2E mode (item 1, test-host isolation — the suite used
    /// to mutate production config/store state through the host app).
    /// Resolved lazily from the process environment on the FIRST path
    /// read; `ModelProxyApp.init` touches `AppPaths` before any store
    /// does, so the redirect is in place for every later consumer.
    nonisolated static let isolatedBase: URL? = {
        guard isolationWanted(environment: ProcessInfo.processInfo.environment) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-test-host-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            // Never block launch on this — fall back to live paths (the
            // pre-isolation behavior) rather than crashing the host.
            NSLog("[ZGate] AppPaths: test-host isolation dir create failed (\(error)) — keeping live paths")
            return nil
        }
    }()

    /// True when the environment asks for test-host isolation: either the
    /// scheme's explicit `ZGATE_TEST_HOST_ISOLATION=1` opt-in or the generic
    /// "this process is an XCTest host" marker (`XCTestConfigurationFilePath`
    /// — auto test plans do not forward scheme env vars, so this is the
    /// reliable signal), unless `ZGATE_E2E=1` overrides it (E2E mode keeps
    /// live-path behavior — its tests deliberately drive a staged app and
    /// read on-disk artifacts).
    nonisolated static func isolationWanted(environment: [String: String]) -> Bool {
        // Only the explicit "=1" opts into E2E live-path mode; any other
        // value (e.g. a stray "0") must NOT silently restore the
        // production-mutation hazard.
        guard environment["ZGATE_E2E"] != "1" else { return false }
        return environment["ZGATE_TEST_HOST_ISOLATION"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated static var appSupport: URL {
        if let isolatedBase {
            return isolatedBase.appendingPathComponent("ZGate", isDirectory: true)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("ZGate", isDirectory: true)
    }

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
        // An isolated test host must never move production directories
        // (into the temp base or out of it) — the migration is a live-run
        // one-time move only.
        guard isolatedBase == nil else { return }
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
