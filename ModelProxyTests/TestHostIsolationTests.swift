import Foundation
import Testing
@testable import ZGate

/// Item 1 — test-host path isolation. The ZGate scheme sets
/// `ZGATE_TEST_HOST_ISOLATION=1` for the Test action, so the host app
/// redirects its default paths (application-support dir, credential-store
/// base, biz-session cache) to a per-run temp directory before any store
/// reads them — suite runs can never mutate production state again.
/// `ZGATE_E2E=1` disables the redirect: E2E mode deliberately drives the
/// live-path app and reads on-disk artifacts.
@Suite struct TestHostIsolationTests {

    /// The application-support directory this host WOULD resolve without
    /// isolation — computed the same way `AppPaths` does, never written.
    private var liveAppSupportParent: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    @Test func isolationPredicateRequiresOptInAndHonorsE2EOverride() {
        #expect(AppPaths.isolationWanted(environment: ["ZGATE_TEST_HOST_ISOLATION": "1"]))
        // Auto test plans do not forward scheme env vars — the XCTest host
        // marker is the reliable signal.
        #expect(AppPaths.isolationWanted(environment: [
            "XCTestConfigurationFilePath": "/tmp/xctest-config"]))
        #expect(!AppPaths.isolationWanted(environment: [:]))
        #expect(!AppPaths.isolationWanted(environment: ["ZGATE_E2E": "1"]))
        // The E2E override wins over either isolation signal.
        #expect(!AppPaths.isolationWanted(environment: [
            "ZGATE_TEST_HOST_ISOLATION": "1",
            "ZGATE_E2E": "1",
        ]))
        #expect(!AppPaths.isolationWanted(environment: [
            "XCTestConfigurationFilePath": "/tmp/xctest-config",
            "ZGATE_E2E": "1",
        ]))
        // Only "=1" opts into E2E live-path mode — a stray other value
        // (e.g. "0") must not silently restore the production-mutation
        // hazard.
        #expect(AppPaths.isolationWanted(environment: [
            "XCTestConfigurationFilePath": "/tmp/xctest-config",
            "ZGATE_E2E": "0",
        ]))
    }

    @Test func hostAppliedIsolationToApplicationSupport() throws {
        // The scheme exported the opt-in, so the running host resolved a
        // per-run temp base before any path consumer read it.
        let isolated = try #require(AppPaths.isolatedBase)
        #expect(AppPaths.appSupport.path.hasPrefix(isolated.path))
        #expect(!AppPaths.appSupport.path.contains("Application Support"))
        #expect(AppPaths.appSupport.deletingLastPathComponent() != liveAppSupportParent)
    }

    /// `ZGATE_APP_SUPPORT_DIR` (the E2E rig / live-probe redirect) is the
    /// highest-priority path signal — it must work without any isolation
    /// marker, ignore empty values, and never fire for this host (which
    /// does not set it).
    @Test func explicitAppSupportOverrideParsing() {
        #expect(
            AppPaths.overrideDir(environment: ["ZGATE_APP_SUPPORT_DIR": "/tmp/rig-home"])?.path
                == "/tmp/rig-home")
        #expect(AppPaths.overrideDir(environment: ["ZGATE_APP_SUPPORT_DIR": ""]) == nil)
        #expect(AppPaths.overrideDir(environment: [:]) == nil)
        #expect(AppPaths.appSupportOverride == nil)
    }

    @Test func isolationCoversCredentialStoreDefaultBase() throws {
        let isolated = try #require(AppPaths.isolatedBase)
        #expect(CredentialStore.defaultBase.path.hasPrefix(isolated.path))
        #expect(!CredentialStore.defaultBase.path.hasPrefix(NSHomeDirectory()))
    }

    @Test func isolationCoversBizSessionCacheDefaultFile() {
        #expect(BizSessionCache.defaultFileURL().deletingLastPathComponent() == AppPaths.appSupport)
    }

    /// The lineage store's default file rides the same resolution (fix
    /// round 1, 2026-11-20): it used to build `…/Application Support/ZGate`
    /// straight from `applicationSupportDirectory`, bypassing every path
    /// signal — a staged build under `ZGATE_APP_SUPPORT_DIR` (or an isolated
    /// test host) would have written lineages to the LIVE dir. The equality
    /// pins the derivation through `AppPaths.appSupport`, so whatever that
    /// resolves (test-host base, explicit redirect) is where lineages go.
    @Test func isolationCoversLineageStoreDefaultFile() {
        #expect(LineageStoreFactory.defaultFileURL().deletingLastPathComponent() == AppPaths.appSupport)
    }
}
