import Foundation
import Testing
@testable import ZGate

/// Task 10 E2E smoke — real app, real Claude Code, real relay.
///
/// Division of labor (documented in docs/e2e-checklist.md): the GUI-bound
/// steps live in `scripts/e2e/zgate-up.sh` / `zgate-down.sh` — they build the
/// isolated app, swap in the default-rule-table config + seeded signing
/// cache, launch the app, and click its status item once (listeners start at
/// app launch; the click exercises the idempotent popover start path —
/// macOS 26.2 needs a real CGEvent click). This
/// suite then drives the actual `claude` invocations and asserts on the
/// app's on-disk request log (`~/Library/Application Support/ModelProxy/
/// logs/modelproxy-<date>.log` — the E2E app and this test host resolve the
/// same directory) plus the app's own persisted artifacts.
///
/// Run (from the repo root, after `scripts/e2e/zgate-up.sh`):
///
///     TEST_RUNNER_ZGATE_E2E=1 TEST_RUNNER_ZGATE_E2E_PHASE=A \
///       xcodebuild -project ZGate.xcodeproj -scheme ZGate \
///       -destination 'platform=macOS' test -only-testing:ZGateTests/E2ESmokeTests
///
/// `TEST_RUNNER_` is the xcodebuild convention for forwarding env into the
/// test host. PHASE=A covers AC1/AC3; PHASE=B covers AC2 (glm-5.3-flash
/// rides the relay fast tier — since v2.1 no default route touches splash,
/// so the old splash-up/down halves collapsed into one check). The suite
/// skips entirely unless ZGATE_E2E=1.
@Suite
struct E2ESmokeTests {

    // MARK: - Environment

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var phase: String { env["ZGATE_E2E_PHASE"] ?? "A" }
    private static var port: Int { Int(env["ZGATE_E2E_PORT"] ?? "") ?? 8787 }

    private static var appLogFile: URL {
        AppPaths.appSupport.appendingPathComponent("logs/modelproxy-\(Self.today).log")
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Gate helpers

    /// Fails (not skips) when the gate is on but the app is not up — a gated
    /// run that cannot exercise anything is a broken run, not a pass.
    private func requireAppUp() async throws {
        let url = URL(string: "http://127.0.0.1:\(Self.port)/api/hello")!
        let ok = await withCheckedContinuation { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3
            URLSession.shared.dataTask(with: request) { _, response, _ in
                // The proxy answers HEAD locally; ANY HTTP response proves a
                // listener is bound. Transport errors mean nothing is there.
                continuation.resume(returning: response != nil)
            }.resume()
        }
        if !ok {
            Issue.record("nothing is listening on 127.0.0.1:\(Self.port) — run scripts/e2e/zgate-up.sh first")
        }
        #expect(ok)
    }

    // MARK: - Claude Code driver

    /// One isolated `claude` invocation: empty environment (upstream cc.sh
    /// pattern — nothing inherited from the developer's own Claude Code),
    /// its own CLAUDE_CONFIG_DIR + workspace, the proxy as base URL.
    @discardableResult
    private func runClaude(_ arguments: [String], workDir: URL, timeout: TimeInterval = 240) async throws -> String {
        let fm = FileManager.default
        let configDir = workDir.appendingPathComponent("cc-home", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir.appendingPathComponent("tmp"), withIntermediateDirectories: true)

        let home = fm.homeDirectoryForCurrentUser.path
        let claudePath = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ].first { fm.isExecutableFile(atPath: $0) }
            ?? "claude"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = workDir
        process.arguments = arguments
        process.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/usr/local/bin:\(home)/.local/bin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "TMPDIR": workDir.appendingPathComponent("tmp").path,
            "CLAUDE_CONFIG_DIR": configDir.path,
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(Self.port)",
            "ANTHROPIC_API_KEY": "sk-ant-zgate-e2e-dummy",
            "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1",
            "DISABLE_AUTOUPDATER": "1",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let deadline = Date().addingTimeInterval(timeout)
        try process.run()

        var out = Data()
        var err = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            out.append(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            err.append(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }

        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            process.terminate()
            Issue.record("claude timed out after \(Int(timeout))s: \(String(decoding: err, as: UTF8.self).suffix(400))")
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        let output = String(decoding: out, as: UTF8.self)
        if process.terminationStatus != 0 {
            Issue.record(
                "claude exited \(process.terminationStatus)\nstdout: \(output.suffix(400))\nstderr: \(String(decoding: err, as: UTF8.self).suffix(400))")
        }
        #expect(process.terminationStatus == 0)
        return output
    }

    // MARK: - App request-log reading

    private func readLog() throws -> [String] {
        let data = try Data(contentsOf: Self.appLogFile)
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
    }

    /// Waits for log lines appended after `baseline` to satisfy `predicate`.
    /// Log writes are async (AppLogManager → LogFileActor), so a small poll
    /// window follows the CLI's exit.
    private func waitForNewLogLines(
        after baseline: [String],
        timeout: TimeInterval = 15,
        _ predicate: ([String]) -> [String]
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let appended = try readLog().dropFirst(baseline.count)
            let hits = predicate(Array(appended))
            if !hits.isEmpty { return hits }
            try await Task.sleep(for: .milliseconds(500))
        }
        let appended = try readLog().dropFirst(baseline.count)
        return predicate(Array(appended))
    }

    /// `requestID` of a proxy log line, e.g. "[Proxy] [a1b2c3] POST …" → a1b2c3.
    private static func requestID(of line: String) -> String? {
        guard let range = line.range(of: #"\[Proxy\] \[([^\]]+)\]"#, options: .regularExpression) else {
            return nil
        }
        let bracketed = String(line[range])
        return bracketed
            .dropFirst("[Proxy] [".count)
            .dropLast("]".count)
            .description
    }

    private func freshWorkDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-e2e-cc/\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Config: the default rule table is what serves (AC0 sanity)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_E2E"] == "1"
        && ProcessInfo.processInfo.environment["ZGATE_E2E_PHASE"]?.uppercased() != "B"))
    func liveConfigIsTheDefaultRuleTable() throws {
        let data = try Data(contentsOf: AppPaths.appSupport.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // Pre-migration guard: the wave-1 live shape pinned sonnet → relay
        // GLM-5.3-Flash. If that row is still there the new app has not
        // launched against this config yet — name the cause instead of
        // failing a cascade of shape expectations below.
        if config.modelMappings.contains(where: {
            $0.matchClass == .sonnet && $0.targetModel == "GLM-5.3-Flash"
        }) {
            Issue.record(
                "live config not yet migrated — launch the new app once to run migration 5 (sonnet row still targets GLM-5.3-Flash)")
            return
        }

        // The v2.1 matrix (owner ruling 2026-11-17), by class, in the LIVE
        // config's rule order — the live config keeps its wave-1 order
        // (auto, haiku, sonnet, opus, opus); migrations bring the rest:
        // migration 3 seeds the splash section, migration 4 inserts the auto
        // peak twin (DISABLED) at the top, migration 5 retargets sonnet →
        // GLM-5.3 / haiku → relay GLM-5.3-Flash (backups dropped) and
        // disables every conditioned rule — so BOTH twins ship as the
        // dormant cost lever, and exactly they are the disabled rows.
        let classRules = config.modelMappings.filter { $0.matchClass != nil }
        #expect(classRules.map(\.matchClass) == [.auto, .auto, .haiku, .sonnet, .opus, .opus])
        #expect(config.modelMappings.last?.catchAll == true)
        #expect(config.splash != nil)
        let disabled = config.modelMappings.filter { !$0.isEnabled }
        #expect(disabled.map(\.sourceModel).sorted() == ["auto (peak hours)", "opus (peak hours)"])

        let relay = config.vendors.first { $0.vendorKind == .relay }
        let splash = config.vendors.first { $0.name.hasPrefix("splash") }
        #expect(relay?.baseURL == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")
        #expect(splash?.baseURL == "http://127.0.0.1:8000")

        // Resolution through the REAL router code (no condition seams needed
        // — disabled twins never match; first eligible enabled rule wins),
        // against the v2.1 all-relay matrix: ALL deliberate work rides
        // opus-class GLM-5.3 on the relay — the bare glm-5.3 prefix now
        // classifies .opus (AC1's path) and a sonnet-class name hits the
        // sonnet row → the same GLM-5.3; haiku-class work (glm-5.3-flash,
        // the fast background tier) → relay GLM-5.3-Flash as a SINGLE
        // target (no splash primary, no backup — local qwen is off every
        // default route); an unknown model → the terminal catch-all
        // (relay GLM-5.3-Flash).
        let client = try #require(config.clients.first { $0.clientName == "Claude Code" })
        let snapshot = RoutingSnapshot(from: config, for: client)

        // v2.1: bare glm-5.3 prefix → .opus → relay GLM-5.3.
        let opus = snapshot.resolve(model: "glm-5.3", originalAPIKey: "")
        guard case .routed(let opusTarget) = opus.result else {
            Issue.record("glm-5.3 did not route"); return
        }
        #expect(opusTarget.vendorName == "zcode relay")
        #expect(opusTarget.targetModel == "GLM-5.3")

        // Sonnet-class work rides the same opus-class relay model.
        let sonnet = snapshot.resolve(model: "claude-sonnet-4-5", originalAPIKey: "")
        guard case .routed(let sonnetTarget) = sonnet.result else {
            Issue.record("sonnet-class model did not route"); return
        }
        #expect(sonnetTarget.vendorName == "zcode relay")
        #expect(sonnetTarget.targetModel == "GLM-5.3")

        // glm-5.3-flash → haiku → the fast relay tier, one target only.
        let flashTargets = snapshot.targets(for: "glm-5.3-flash") ?? []
        #expect(flashTargets.count == 1)
        #expect(flashTargets.first?.vendorName == "zcode relay")
        #expect(flashTargets.first?.targetModel == "GLM-5.3-Flash")

        // "fable" would classify as opus — pick a name no class rule matches.
        let unknown = snapshot.resolve(model: "unknown-model-x", originalAPIKey: "")
        guard case .routed(let catchAll) = unknown.result else {
            Issue.record("unknown model did not route"); return
        }
        #expect(catchAll.vendorName == "zcode relay")
        #expect(catchAll.targetModel == "GLM-5.3-Flash")
    }

    // MARK: - AC1: signed relay round-trip

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_E2E"] == "1"
        && ProcessInfo.processInfo.environment["ZGATE_E2E_PHASE"]?.uppercased() != "B"))
    func ac1_sayOKRidesTheSignedRelay() async throws {
        try await requireAppUp()
        let baseline = try readLog()
        let output = try await runClaude(["-p", "say OK", "--model", "glm-5.3"], workDir: try freshWorkDir("ac1"))
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")

        // The request hit the relay rule and a 200 came back through it. A
        // 200 from zcode.z.ai only happens with the V4 signing quartet —
        // the relay 401s valid tokens unsigned (RelayTarget failure policy).
        let routed = try await waitForNewLogLines(after: baseline) { appended in
            appended.filter {
                $0.contains("POST /v1/messages")
                    && $0.contains("model=glm-5.3")
                    && $0.contains("mapped → zcode relay")
                    && !$0.contains("count_tokens")
            }
        }
        #expect(!routed.isEmpty)

        let ids = routed.compactMap { Self.requestID(of: $0) }
        let served = try await waitForNewLogLines(after: baseline) { appended in
            appended.filter { line in
                line.contains("Response: 200") && line.contains("vendor=zcode relay")
                    && ids.contains { line.contains("[\($0)]") }
            }
        }
        #expect(!served.isEmpty)
    }

    // MARK: - AC2: haiku class rides the relay fast tier (v2.1)

    // v2.1 retired the splash round-trip: no default route touches local
    // qwen, so the old splash-up (ac2a) / splash-down (ac2b) split collapsed
    // into one truth — glm-5.3-flash maps to relay GLM-5.3-Flash directly
    // (single target, pinned by the config test above). Kept on PHASE=B so
    // the driver's existing phase flow still exercises it; splash's state is
    // irrelevant to the outcome now.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_E2E"] == "1"
        && ProcessInfo.processInfo.environment["ZGATE_E2E_PHASE"]?.uppercased() == "B"))
    func ac2b_haikuClassRidesRelayFlash() async throws {
        try await requireAppUp()
        let baseline = try readLog()
        let output = try await runClaude(
            ["-p", "say OK", "--model", "glm-5.3-flash"], workDir: try freshWorkDir("ac2b"))
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")

        // Two-stage (ac1's pattern): wait for the routed line first, then
        // wait for its Response — a single snapshot can miss the Response
        // line when the log flushes it after the first non-empty poll.
        let flashRequests = try await waitForNewLogLines(after: baseline, timeout: 20) { appended in
            appended.filter {
                $0.contains("POST /v1/messages") && $0.contains("model=glm-5.3-flash")
                    && $0.contains("mapped → zcode relay")
            }
        }
        #expect(!flashRequests.isEmpty)

        // The request mapped to the relay (not splash) and the relay served
        // it 200. The route log prints the vendor only — haiku rule vs
        // catch-all is indistinguishable here, and under v2.1 both targets
        // are GLM-5.3-Flash anyway; the config test's targets(for:)
        // assertion pins the haiku rule's single target.
        let ids = flashRequests.compactMap { Self.requestID(of: $0) }
        let served = try await waitForNewLogLines(after: baseline, timeout: 20) { appended in
            appended.filter { line in
                line.contains("Response: 200") && line.contains("vendor=zcode relay")
                    && ids.contains { line.contains("[\($0)]") }
            }
        }
        #expect(!served.isEmpty)
    }

    // MARK: - AC3: streaming tool-use round-trip

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_E2E"] == "1"
        && ProcessInfo.processInfo.environment["ZGATE_E2E_PHASE"]?.uppercased() != "B"))
    func ac3_toolUseRoundTripStreamsThroughProxy() async throws {
        try await requireAppUp()

        // The canary cannot be answered without the Read tool actually
        // running: the model has never seen the file.
        let canary = "zgate-e2e-canary-\(UUID().uuidString.prefix(8))"
        let work = try freshWorkDir("ac3")
        try "\(canary)\n".write(
            to: work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let baseline = try readLog()
        let output = try await runClaude(
            [
                "-p",
                "Read notes.txt in the current directory and reply with exactly the marker line it contains, nothing else.",
                "--model", "glm-5.3",
                // Equals form: --allowedTools is variadic and would swallow a
                // following positional prompt (the failure of the first run).
                "--allowedTools=Read",
            ],
            workDir: work, timeout: 300)
        #expect(output.contains(canary))

        // A tool round-trip is at least two relayed generation turns (the
        // tool_use request, then the tool_result follow-up).
        let turns = try await waitForNewLogLines(after: baseline, timeout: 20) { appended in
            appended.filter {
                $0.contains("POST /v1/messages")
                    && $0.contains("model=glm-5.3")
                    && $0.contains("mapped → zcode relay")
                    && !$0.contains("count_tokens")
            }
        }
        #expect(turns.count >= 2)
        let ids = turns.compactMap { Self.requestID(of: $0) }
        let served = try await waitForNewLogLines(after: baseline, timeout: 20) { appended in
            appended.filter { line in
                line.contains("Response: 200") && line.contains("vendor=zcode relay")
                    && ids.contains { line.contains("[\($0)]") }
            }
        }
        #expect(served.count >= 2)
    }

    // MARK: - AC4: metering procedure stays an unchecked scaffold

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_E2E"] == "1"))
    func ac4_meteringProcedureDocumentedUnchecked() throws {
        // The repo lives on a removable volume: a headless test host's open()
        // on it blocks forever in the removable-volume TCC check (found the
        // hard way — two runs hung in open(), never returned). The driver
        // stages a copy and hands its path over; the repo path is only a
        // fallback for hosts that do have the grant.
        let checklist = URL(fileURLWithPath: Self.env["ZGATE_E2E_CHECKLIST"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // ModelProxyTests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("docs/e2e-checklist.md")
                .path)
        let text = try String(contentsOf: checklist, encoding: .utf8)

        let procedure = "With the user present: run one identical small payload via ZGate (ANTHROPIC_BASE_URL=127.0.0.1:8787) and once direct via api.z.ai/api/anthropic; record balance deltas from the app/plan dashboard before/after each; compute the metering ratio; redact values in this file before any commit or keep the filled section git-ignored."
        #expect(text.contains(procedure))
        #expect(text.contains("requires user present"))

        // The AC4 box stays unchecked until the procedure runs with the user.
        if let range = text.range(of: procedure) {
            let box = text[..<range.lowerBound].suffix(6)
            #expect(!box.contains("[x]"))
        }
    }
}
