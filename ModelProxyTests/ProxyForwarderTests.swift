import AsyncHTTPClient
import Foundation
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

struct ProxyForwarderTests {

    @Test func branchWaitBudgetStopsAfterConfiguredLimit() {
        var budget = ProxyForwarder.BranchWaitBudget(maxAttempts: 3)

        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == false)
        #expect(budget.attempts == 4)
    }

    @Test func headProbeIsAnsweredLocally() {
        let probe = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/api/hello")
        let messages = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages?beta=true")

        #expect(ProxyForwarder.isLocalProbe(probe))
        #expect(!ProxyForwarder.isLocalProbe(messages))
    }

    @Test func sendResponseWithEmptyBodyWritesZeroContentLengthAndNoBodyPart() async throws {
        let channel = EmbeddedChannel()

        await ProxyForwarder.sendResponse(channel: channel, status: .ok, contentType: nil, body: Data())

        let headPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let head) = headPart else {
            Issue.record("Expected response head"); return
        }
        #expect(head.status == .ok)
        #expect(head.headers["content-length"] == ["0"])
        #expect(!head.headers.contains(name: "content-type"))
        let endPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .end = endPart else {
            Issue.record("Expected response end directly after head"); return
        }
    }

    @Test func sendErrorWritesHeadBodyAndEndWithoutWaitingForAFlush() async throws {
        let channel = EmbeddedChannel()

        await ProxyForwarder.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable")

        let headPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let head) = headPart else {
            Issue.record("Expected response head"); return
        }
        #expect(head.status == .badGateway)
        #expect(head.headers["content-length"] == ["20"])
        let bodyPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .body(.byteBuffer(let buffer)) = bodyPart else {
            Issue.record("Expected response body"); return
        }
        #expect(buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) == "Upstream unreachable")
        let endPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .end = endPart else {
            Issue.record("Expected response end"); return
        }
    }

    @Test func claudeCodeHeadersGiveSessionAndAgentCoordinationScope() {
        let main: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1"]
        let subagent: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1", "x-claude-code-agent-id": "agent-7"]
        let body = Data(#"{"model":"claude-sonnet-5","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let shape = ProxyForwarder.requestShapeFingerprint(body)

        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: main, bodyData: body, clientName: "Claude Code")
            == "Claude Code|cc-session|sess-1|shape|\(shape)")
        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: subagent, bodyData: body, clientName: "Claude Code")
            == "Claude Code|cc-session|sess-1|agent|agent-7|shape|\(shape)")
        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: [:], bodyData: body, clientName: "Claude Code") == nil)
    }

    @Test func claudeCodeScopeSeparatesConcurrentRequestsThatOnlyShareMessages() {
        let headers: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1"]
        func scope(_ json: String) -> String? {
            ProxyForwarder.claudeCodeCoordinationScopeKey(headers: headers, bodyData: Data(json.utf8), clientName: "Claude Code")
        }
        let apple = #"{"model":"claude-sonnet-5","system":"Answer APPLE","messages":[{"role":"user","content":"word?"}]}"#
        let banana = #"{"model":"claude-sonnet-5","system":"Answer BANANA","messages":[{"role":"user","content":"word?"}]}"#
        let otherModel = #"{"model":"claude-haiku-4-5","system":"Answer APPLE","messages":[{"role":"user","content":"word?"}]}"#
        let appleLaterTurn = #"{"system":"Answer APPLE","model":"claude-sonnet-5","messages":[{"role":"user","content":"word?"},{"role":"assistant","content":"APPLE"},{"role":"user","content":"again"}]}"#

        // Same messages but a different system prompt or model must not share in-flight coordination.
        #expect(scope(apple) != scope(banana))
        #expect(scope(apple) != scope(otherModel))
        // A retry or a later turn of the same request shape stays in one scope, regardless of key order.
        #expect(scope(apple) == scope(apple))
        #expect(scope(apple) == scope(appleLaterTurn))
    }

    @Test func claudeCodeRequestClassComesFromHintHeaderOrAgentID() {
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-request-class": "compaction"]) == .compaction)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-agent-id": "agent-7"]) == .subagent)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-request-class": "unknown-class"]) == nil)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: [:]) == nil)
    }

    @Test func mappedVendorsDoNotReceiveClaudeCodeHeadersOrClientCredentials() {
        let request: HTTPHeaders = [
            "x-api-key": "client-key",
            "anthropic-version": "2023-06-01",
            "X-Claude-Code-Session-Id": "sess-1",
            "x-claude-code-agent-id": "agent-7",
            "Host": "localhost:8080"
        ]
        let mapped = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let passthrough = countTokensTarget(supportsCountTokens: true, isPassthrough: true)

        let vendorHeaders = ProxyForwarder.upstreamHeaders(from: request, target: mapped)
        #expect(!vendorHeaders.contains(name: "x-claude-code-session-id"))
        #expect(!vendorHeaders.contains(name: "x-claude-code-agent-id"))
        #expect(vendorHeaders["x-api-key"] == ["vendor-key"])
        #expect(vendorHeaders["anthropic-version"] == ["2023-06-01"])
        #expect(vendorHeaders["host"] == ["api.deepseek.com"])

        let passthroughHeaders = ProxyForwarder.upstreamHeaders(from: request, target: passthrough)
        #expect(passthroughHeaders["x-claude-code-session-id"] == ["sess-1"])
        #expect(passthroughHeaders["x-api-key"] == ["client-key"])
    }

    @Test func stripClaudeOnlyRequestFieldsRemovesBodyAndToolFieldsOnly() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-5-5",
            "max_tokens": 1024,
            "thinking": ["type": "adaptive"],
            "context_management": ["edits": [["type": "clear_tool_uses_20250919"]]],
            "output_config": ["effort": "xhigh"],
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "name": "Bash",
                "input_schema": ["type": "object"],
                "strict": true,
                "eager_input_streaming": true,
                "cache_control": ["type": "ephemeral"]
            ]]
        ])

        let result = ProxyForwarder.stripClaudeOnlyRequestFields(in: body)

        #expect(result.removedFields == ["context_management", "output_config", "tools[].eager_input_streaming", "tools[].strict"])
        let json = try #require(try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any])
        #expect(json["context_management"] == nil)
        #expect(json["output_config"] == nil)
        #expect(json["thinking"] != nil)
        #expect(json["max_tokens"] as? Int == 1024)
        let tool = try #require((json["tools"] as? [[String: Any]])?.first)
        #expect(tool["strict"] == nil)
        #expect(tool["eager_input_streaming"] == nil)
        #expect(tool["cache_control"] != nil)
        #expect(tool["input_schema"] != nil)
    }

    @Test func stripClaudeOnlyRequestFieldsLeavesBytesUntouchedWhenNothingToRemove() throws {
        let body = Data(#"{"model":"claude-opus-5-5","messages":[{"role":"user","content":"hi"}]}"#.utf8)

        let result = ProxyForwarder.stripClaudeOnlyRequestFields(in: body)

        #expect(result.bodyData == body)
        #expect(result.removedFields.isEmpty)
    }

    @Test func anthropicBetaHeaderIsDroppedOnlyForStrippingVendors() {
        let request: HTTPHeaders = ["anthropic-beta": "context-management-2025-06-27", "anthropic-version": "2023-06-01"]
        let base = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let stripping = RoutingSnapshot.RouteTarget(
            baseURL: base.baseURL,
            apiKey: base.apiKey,
            vendorName: base.vendorName,
            vendorID: base.vendorID,
            targetModel: base.targetModel,
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            stripsClaudeOnlyRequestFields: true
        )

        #expect(ProxyForwarder.upstreamHeaders(from: request, target: base)["anthropic-beta"] == ["context-management-2025-06-27"])
        #expect(!ProxyForwarder.upstreamHeaders(from: request, target: stripping).contains(name: "anthropic-beta"))
        #expect(ProxyForwarder.upstreamHeaders(from: request, target: stripping)["anthropic-version"] == ["2023-06-01"])
    }

    @Test func fallbackEdgeHeadersCarryAPIKeyWithoutAuthorization() {
        // CLI zai-api provider template: the credential rides x-api-key and
        // replaces the authorization header entirely.
        let request: HTTPHeaders = ["anthropic-version": "2023-06-01"]
        let edge = RoutingSnapshot.RouteTarget(
            baseURL: ApiKeyMinter.fallbackBaseURL,
            apiKey: "ak-1.sk-1",
            vendorName: "z.ai API key (fallback)",
            vendorID: UUID(),
            targetModel: "GLM-5.3-Flash",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 300,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            stripsClaudeOnlyRequestFields: true,
            applyGLMCanonicalization: true)

        let headers = ProxyForwarder.upstreamHeaders(from: request, target: edge)
        #expect(headers["x-api-key"] == ["ak-1.sk-1"])
        #expect(!headers.contains(name: "authorization"))
        #expect(headers["host"] == ["api.z.ai"])
        #expect(headers["anthropic-version"] == ["2023-06-01"])

        // Every other vendor keeps the Bearer + x-api-key pair.
        let plain = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let plainHeaders = ProxyForwarder.upstreamHeaders(from: request, target: plain)
        #expect(plainHeaders["authorization"] == ["Bearer vendor-key"])
        #expect(plainHeaders["x-api-key"] == ["vendor-key"])
    }

    @Test func restoredThinkingBlockCountMeasuresOnlyBlocksTheClientDidNotSend() throws {
        func body(thinkingBlocks: Int) throws -> Data {
            let thinking = Array(repeating: ["type": "thinking", "thinking": "t"], count: thinkingBlocks)
            return try JSONSerialization.data(withJSONObject: [
                "model": "m",
                "messages": [
                    ["role": "user", "content": "q"],
                    ["role": "assistant", "content": thinking + [["type": "text", "text": "a"]]]
                ]
            ])
        }

        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 0), preparedBody: try body(thinkingBlocks: 2)) == 2)
        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 2), preparedBody: try body(thinkingBlocks: 2)) == 0)
        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 2), preparedBody: try body(thinkingBlocks: 0)) == 0)
    }

    @Test func countTokensIsAnsweredLocallyWhenVendorLacksEndpoint() {
        let vendor = countTokensTarget(supportsCountTokens: false, isPassthrough: false)

        #expect(ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: vendor))
        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .generation, target: vendor))
    }

    @Test func countTokensIsForwardedWhenVendorSupportsEndpointOrRouteIsPassthrough() {
        let supporting = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let passthrough = countTokensTarget(supportsCountTokens: false, isPassthrough: true)

        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: supporting))
        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: passthrough))
    }

    @Test func countTokensUnsupportedBodyIsAnthropicNotFoundError() throws {
        let data = ProxyForwarder.countTokensUnsupportedBody(vendorName: "DeepSeek")
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])

        #expect(json["type"] as? String == "error")
        #expect(error["type"] as? String == "not_found_error")
        #expect((error["message"] as? String)?.contains("DeepSeek") == true)
    }

    private func countTokensTarget(supportsCountTokens: Bool, isPassthrough: Bool) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "vendor-key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1"),
            targetModel: "deepseek-v4-pro[1m]",
            isPassthrough: isPassthrough,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: supportsCountTokens,
            repairsAnthropicToolCalls: true
        )
    }

    @Test func sanitizeToolsRemovesToolsWithEmptyName() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "", "input_schema": ["type": "object"]],
                ["name": "bash", "input_schema": ["type": "object", "properties": [:]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "bash")
    }

    @Test func sanitizeToolsRemovesToolsWithMissingInputSchema() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "advisor", "type": "custom"],
                ["name": "bash", "input_schema": ["type": "object"]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "bash")
    }

    @Test func sanitizeToolsRemovesServerSideToolsByType() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
                ["type": "computer_20241022", "name": "computer", "display_width_px": 1024],
                ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "Read")
    }

    @Test func sanitizeToolsRemovesToolChoiceWhenAllToolsFiltered() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
            ],
            "tool_choice": ["type": "auto"]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect(json["tools"] == nil)
        #expect(json["tool_choice"] == nil)
    }

    @Test func sanitizeToolsPassesThroughValidToolsUnchanged() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "bash", "input_schema": ["type": "object"]],
                ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
    }

    // MARK: - Off-peak rule-target dispatch (off-peak wave 2, Task 4)

    /// One local SwiftNIO server playing either stub role these tests need:
    /// the off-peak origin (ticket control plane + data plane, scripted by
    /// path) or the rule's backup upstream. FIXED ports below the ephemeral
    /// range (the ConnectRetryTests lesson — a `:0` bind can steal a port a
    /// concurrently-running suite expects free). All credentials synthetic.
    private final class DispatchStubServer: @unchecked Sendable {
        struct Recorded {
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data?

            var jsonBody: [String: Any]? {
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            }

            func header(_ name: String) -> String? { headers[name.lowercased()] }
        }

        struct Script {
            var status: Int = 200
            var headers: [String: String] = ["content-type": "application/json"]
            var chunks: [Data] = []

            static func json(_ object: [String: Any], status: Int = 200) -> Script {
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                return Script(status: status, chunks: [data])
            }

            static func envelope(_ json: String) -> Script {
                Script(chunks: [Data(json.utf8)])
            }
        }

        private let lock = NSRecursiveLock()
        private var _recorded: [Recorded] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?
        private var channels: [any Channel] = []
        var respond: ((Recorded) -> Script)?
        private static let portBase = 24_280

        var recorded: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return _recorded
        }

        func requests(at path: String) -> [Recorded] {
            recorded.filter { $0.path == path }
        }

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(DispatchStubHandler(server: self))
                    }
                }
            var lastError: Error?
            for offset in 0..<64 {
                do {
                    let channel = try await bootstrap.bind(
                        host: "127.0.0.1", port: Self.portBase + offset
                    ).get()
                    lock.lock()
                    serverChannel = channel
                    lock.unlock()
                    return channel.localAddress?.port ?? 0
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NSError(domain: "DispatchStubServer", code: 1)
        }

        func shutdown() async {
            lock.lock()
            let all = channels + [serverChannel].compactMap { $0 }
            serverChannel = nil
            channels = []
            lock.unlock()
            for channel in all {
                try? await channel.close().get()
            }
            try? await group.shutdownGracefully()
        }

        fileprivate func record(_ request: Recorded) {
            lock.lock(); _recorded.append(request); lock.unlock()
        }

        fileprivate func answer(for request: Recorded) -> Script {
            lock.lock(); defer { lock.unlock() }
            return respond?(request) ?? Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
        }

        fileprivate func track(_ channel: any Channel) {
            lock.lock(); channels.append(channel); lock.unlock()
        }
    }

    private final class DispatchStubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: DispatchStubServer
        private var head: HTTPRequestHead?
        private var body = Data()

        init(server: DispatchStubServer) { self.server = server }

        func handlerAdded(context: ChannelHandlerContext) {
            server.track(context.channel)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h):
                head = h
                body = Data()
            case .body(let buffer):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .end:
                guard let head else {
                    context.close(promise: nil)
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                let recorded = DispatchStubServer.Recorded(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: headers,
                    body: body.isEmpty ? nil : body)
                server.record(recorded)
                respond(context: context, script: server.answer(for: recorded))
                self.head = nil
                body = Data()
            }
        }

        private func respond(context: ChannelHandlerContext, script: DispatchStubServer.Script) {
            let channel = context.channel
            Task {
                var responseHead = HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: script.status))
                var isSSE = false
                for (name, value) in script.headers {
                    if name.lowercased() == "content-type",
                        value.lowercased().contains("text/event-stream")
                    {
                        isSSE = true
                    }
                    responseHead.headers.add(name: name, value: value)
                }
                let total = script.chunks.reduce(0) { $0 + $1.count }
                if !isSSE {
                    responseHead.headers.replaceOrAdd(
                        name: "content-length", value: String(total))
                }
                channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                for chunk in script.chunks {
                    var buffer = channel.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    channel.flush()
                }
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            }
        }
    }

    /// Test stub for the window gate: a fixed `isWindowOpen` behind a lock —
    /// the cached read the hot path is allowed.
    private final class WindowGateStub: OffPeakAvailabilityMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private var open: Bool

        init(open: Bool) { self.open = open }

        var isWindowOpen: Bool {
            lock.lock(); defer { lock.unlock() }
            return open
        }
    }

    private typealias OffPeakFixture = (
        router: RequestRouter, trafficLog: TrafficLog, tokenStatsStore: TokenStatsStore,
        lineageBroker: SessionLineageBroker, portableNormalizer: PortableContentNormalizer,
        requestCoordinator: BranchRequestCoordinator, offPeakVendorID: UUID, directory: URL
    )

    /// The wave-2 rule shape: `offpeak-target` maps to the seeded off-peak
    /// vendor as primary, with an optional loopback backup vendor — the
    /// same routing-table shape ProxyServer builds per client. The edge
    /// variant (`backupAPIKey: ""`) mirrors the seeded fallback-edge row:
    /// default vendor kind, empty stored key.
    @MainActor
    private func makeOffPeakFixture(
        backupPort: Int?, backupAPIKey: String = "backup-key-synthetic",
        backupVendorKind: VendorKind = .anthropic
    ) throws -> OffPeakFixture {
        let offPeakVendorID = UUID()
        var vendors = [Vendor(
            id: offPeakVendorID, name: "ZCode Off-Peak",
            baseURL: OffPeakConfig.defaultOrigin, apiKey: "",
            readTimeoutSeconds: 5400, supportsThinkingBlocks: true,
            stripsClaudeOnlyRequestFields: true, applyGLMCanonicalization: true,
            vendorKind: .offPeak)]
        var mapping = ModelMapping(
            sourceModel: "offpeak-target", targetModel: "GLM-5.3",
            targetVendorID: offPeakVendorID, isEnabled: true)
        if let backupPort {
            let backupVendor = Vendor(
                name: "Backup Vendor", baseURL: "http://127.0.0.1:\(backupPort)",
                apiKey: backupAPIKey, readTimeoutSeconds: 10,
                vendorKind: backupVendorKind)
            vendors.append(backupVendor)
            mapping.backupTargetVendorID = backupVendor.id
            mapping.backupTargetModel = "glm-4.7"
        }
        let clientConfig = ClientConfig(
            clientName: "Claude Code", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .block)
        let config = AppConfig(vendors: vendors, clients: [clientConfig], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: clientConfig)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-offpeak-fwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lineageBroker = SessionLineageBroker(
            store: FileLineageStore(fileURL: directory.appendingPathComponent("lineages.json")))
        // Per-test stats directory: two TokenStatsStore instances sharing
        // the real daily file would clobber each other's rows (each
        // persists only its own in-memory snapshot).
        return (
            RequestRouter(snapshot: snapshot), TrafficLog(),
            TokenStatsStore(storageDirectory: directory),
            lineageBroker, PortableContentNormalizer(), BranchRequestCoordinator(),
            offPeakVendorID, directory)
    }

    private func offPeakPostHead() -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages")
        // Synthetic credentials — assert they never leave the machine.
        head.headers.add(name: "x-api-key", value: "client-key-synthetic")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        head.headers.add(name: "content-type", value: "application/json")
        return head
    }

    private static func offPeakBody(stream: Bool) -> String {
        #"{"model":"offpeak-target","max_tokens":64,"stream":\#(stream),"messages":[{"role":"user","content":"héllo"}]}"#
    }

    private static let offPeakFrameStart =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100}}}\n\n"
    private static let offPeakFrameUsage =
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n"
    private static let offPeakFrameStop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    private static var offPeakSSEFrames: String { offPeakFrameStart + offPeakFrameUsage + offPeakFrameStop }

    /// The ticket-plane script: immediate availability, a ready ticket, and
    /// an SSE data plane carrying usage (input 100 / output 7).
    private static func ticketPlaneReadyScript(_ request: DispatchStubServer.Recorded) -> DispatchStubServer.Script {
        switch request.path {
        case "/api/v1/off-peak/ticket/availability":
            return .envelope(#"{"code":0,"data":{"can_take_number":true}}"#)
        case "/api/v1/off-peak/ticket":
            return .envelope(#"{"code":0,"data":{"ticket_id":"tkt-fwd","state":"ready"}}"#)
        case OffPeakTarget.dataPlanePath:
            return DispatchStubServer.Script(
                status: 200, headers: ["content-type": "text/event-stream"],
                chunks: [Data(offPeakSSEFrames.utf8)])
        default:
            return DispatchStubServer.Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
        }
    }

    @MainActor
    private func forwardOffPeak(
        _ fixture: OffPeakFixture, httpClient: HTTPClient, channel: any Channel,
        bodyText: String, offPeakContext: OffPeakTarget.Context?,
        offPeakMonitor: (any OffPeakAvailabilityMonitoring)?,
        relayContext: RelayTarget.Context? = nil
    ) async {
        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeData(Data(bodyText.utf8))
        await ProxyForwarder.forward(
            clientName: "Claude Code",
            head: offPeakPostHead(),
            body: body,
            channel: channel,
            router: fixture.router,
            httpClient: httpClient,
            trafficLog: fixture.trafficLog,
            tokenStatsStore: fixture.tokenStatsStore,
            lineageBroker: fixture.lineageBroker,
            portableNormalizer: fixture.portableNormalizer,
            requestCoordinator: fixture.requestCoordinator,
            webSearchProvider: nil,
            webSearchForwardAsIs: false,
            relayContext: relayContext,
            offPeakContext: offPeakContext,
            offPeakMonitor: offPeakMonitor)
    }

    /// Reads every outbound part of an EmbeddedChannel: (head, concatenated
    /// body bytes, sawEnd).
    private func drainOffPeakResponse(_ channel: EmbeddedChannel) throws -> (HTTPResponseHead, Data, Bool) {
        var head: HTTPResponseHead?
        var body = Data()
        var sawEnd = false
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let h): head = h
            case .body(.byteBuffer(let buffer)):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .body(.fileRegion): break
            case .end: sawEnd = true
            }
        }
        return (try #require(head), body, sawEnd)
    }

    @MainActor
    private func waitUntilOffPeak(
        timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func requestIsStreamRequiresTopLevelStreamTrue() {
        #expect(ProxyForwarder.requestIsStream(Data(#"{"model":"m","stream":true,"messages":[]}"#.utf8)))
        #expect(!ProxyForwarder.requestIsStream(Data(#"{"model":"m","stream":false,"messages":[]}"#.utf8)))
        #expect(!ProxyForwarder.requestIsStream(Data(#"{"model":"m","messages":[]}"#.utf8)))
        // Same tolerance as OffPeakTarget's pre-flight: a string "true" is
        // not a Bool; malformed or non-object bodies are not stream requests.
        #expect(!ProxyForwarder.requestIsStream(Data(#"{"model":"m","stream":"true"}"#.utf8)))
        #expect(!ProxyForwarder.requestIsStream(Data("not json at all".utf8)))
        #expect(!ProxyForwarder.requestIsStream(Data("[]".utf8)))
    }

    @Test @MainActor func routeOffPeakNonStreamRequestFallsBackToBackup() async throws {
        let backup = DispatchStubServer()
        backup.respond = { _ in .json(["servedBy": "backup-marker"]) }
        let backupPort = try await backup.start()
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer {
            Task { await backup.shutdown() }
            Task { await ticketPlane.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: false),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: true))

        // THE CARDINAL RULE: a non-streaming request must never see
        // async_stream_required or silently queue — the backup serves it.
        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("backup-marker") == true)

        // The fallback rode the backup target and ITS model; the client's
        // credentials never left the machine.
        let request = try #require(backup.recorded.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/messages")
        #expect(request.jsonBody?["model"] as? String == "glm-4.7")
        #expect(request.header("x-api-key") == "backup-key-synthetic")
        // The ticket plane was never contacted.
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    @Test @MainActor func routeOffPeakWindowClosedFallsBackToBackup() async throws {
        let backup = DispatchStubServer()
        backup.respond = { _ in .json(["servedBy": "backup-marker"]) }
        let backupPort = try await backup.start()
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer {
            Task { await backup.shutdown() }
            Task { await ticketPlane.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        // A streaming request, but the cached window read says closed: the
        // gate must fail without any availability call on the hot path.
        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: true),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: false))

        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("backup-marker") == true)
        #expect(backup.recorded.count == 1)
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    @Test @MainActor func routeOffPeakDisabledSurfaceFallsBackToBackup() async throws {
        let backup = DispatchStubServer()
        backup.respond = { _ in .json(["servedBy": "backup-marker"]) }
        let backupPort = try await backup.start()
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer {
            Task { await backup.shutdown() }
            Task { await ticketPlane.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: false, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: true),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: true))

        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("backup-marker") == true)
        #expect(backup.recorded.count == 1)
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    @Test @MainActor func routeOffPeakNoBackupAnswers503() async throws {
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer { Task { await ticketPlane.shutdown() } }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        // Single-target rule: no backup exists.
        let fixture = try makeOffPeakFixture(backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: false),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: true))

        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .serviceUnavailable)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "off_peak_unavailable")
        // Final-review fix #3: the terminal names the gate that actually
        // failed (here a non-streaming request with the window OPEN), not a
        // hardcoded "window is closed".
        #expect(
            error["message"] as? String
                == "Off-peak gate failed (non-streaming request) and this rule has no backup target.")
        // The 503 is visible in the traffic log, and nothing upstream moved.
        let entries = await MainActor.run { fixture.trafficLog.entries }
        #expect(entries.last?.httpStatus == 503)
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    // MARK: - Off-peak gate fallback, relay-plane backups (final-review fix #2)

    /// In-memory mint chain (the RelayHealthTests pattern, compacted): one
    /// API key id, an incrementing secret per full chain run. Counts runs so
    /// the edge test can pin the lazy single mint.
    private final class ScriptedMintChain: @unchecked Sendable {
        private let lock = NSLock()
        private var runCount = 0
        private var secretIndex = 0

        var runs: Int {
            lock.lock(); defer { lock.unlock() }
            return runCount
        }

        private func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }

        func respond(path: String) throws -> (Int, Data) {
            if path.contains("getCustomerInfo") {
                lock.lock(); runCount += 1; lock.unlock()
                return (200, json(["code": 0, "data": ["organizations": [
                    ["id": "org-1", "name": "org", "projects": [["id": "proj-1", "name": "p"]]],
                ]]]))
            }
            if path.contains("/copy/") {
                lock.lock(); secretIndex += 1; let index = secretIndex; lock.unlock()
                return (200, json(["code": 0, "data": ["secretKey": "secret-\(index)"]]))
            }
            if path.hasSuffix("/api_keys") {
                return (200, json(["code": 0, "data": ["list": [["id": "apiKey-1", "name": "k"]]]]))
            }
            throw NSError(domain: "ScriptedMintChain", code: 1)
        }
    }

    /// A SigningClient that can never build a chain (no store, no location,
    /// no cache) — the RouterTests pattern: a request reaching the signed
    /// ladder fails fast with the signing-unavailable 502 and nothing is
    /// sent unsigned.
    private static func makeUnusableSigningClient() -> SigningClient {
        var configuration = SigningClient.Configuration()
        configuration.storeLoader = { nil }
        configuration.initialLocation = nil
        configuration.cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-offpeak-fwd-unusable-\(UUID().uuidString).cache")
        return SigningClient(configuration: configuration)
    }

    @Test @MainActor func routeOffPeakClosedWindowEdgeBackupMintsKeyAndServes() async throws {
        // Final-review fix #2: an edge-vendored backup carries the seeded
        // row's EMPTY stored key — the fallback must run the edge key
        // lifecycle (lazy mint via RelayHealth) instead of sending the
        // empty key as-is (a guaranteed 401).
        let edge = DispatchStubServer()
        edge.respond = { _ in .json(["servedBy": "edge-marker"]) }
        let edgePort = try await edge.start()
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer {
            Task { await edge.shutdown() }
            Task { await ticketPlane.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: edgePort, backupAPIKey: "")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let chain = ScriptedMintChain()
        var minterConfiguration = ApiKeyMinter.Configuration()
        minterConfiguration.bizJWTProvider = { "biz-jwt" }
        minterConfiguration.execute = { request in
            try chain.respond(path: request.url?.path ?? "")
        }
        var healthConfiguration = RelayHealth.Configuration()
        healthConfiguration.minter = ApiKeyMinter(configuration: minterConfiguration)
        healthConfiguration.fallbackEdgeBaseURL = "http://127.0.0.1:\(edgePort)"
        let relayContext = RelayTarget.Context(
            signingClient: Self.makeUnusableSigningClient(),
            relayHealth: RelayHealth(configuration: healthConfiguration))

        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        // Window closed: the gate fails and the edge backup serves — with
        // the MINTED credential, not the empty stored key.
        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: true),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: false),
            relayContext: relayContext)

        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("edge-marker") == true)

        let request = try #require(edge.recorded.first)
        #expect(request.header("x-api-key") == "apiKey-1.secret-1")
        #expect(chain.runs == 1)  // lazy mint, exactly one chain run
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    @Test @MainActor func routeOffPeakClosedWindowRelayBackupRunsSignedLadder() async throws {
        // The relay-kind backup branch: the fallback dispatches to the
        // backup's own signed ladder (RelayTarget.execute), NOT a plain
        // upstream send — with an unusable signing chain that answers the
        // ladder's own signing-unavailable 502, and nothing is ever sent
        // unsigned to the backup.
        let backup = DispatchStubServer()
        let backupPort = try await backup.start()
        let ticketPlane = DispatchStubServer()
        let ticketPort = try await ticketPlane.start()
        defer {
            Task { await backup.shutdown() }
            Task { await ticketPlane.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: backupPort, backupVendorKind: .relay)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let relayContext = RelayTarget.Context(
            signingClient: Self.makeUnusableSigningClient())
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: true),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: false),
            relayContext: relayContext)

        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .badGateway)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        #expect(message.localizedCaseInsensitiveContains("signing unavailable"))
        // Nothing reached the backup or the ticket plane unsigned.
        #expect(backup.recorded.isEmpty)
        #expect(ticketPlane.recorded.isEmpty)
        _ = try? client.finish()
    }

    @Test @MainActor func routeOffPeakGatesOpenServesViaTicketPlane() async throws {
        let ticketPlane = DispatchStubServer()
        ticketPlane.respond = { Self.ticketPlaneReadyScript($0) }
        let ticketPort = try await ticketPlane.start()
        let backup = DispatchStubServer()
        let backupPort = try await backup.start()
        defer {
            Task { await ticketPlane.shutdown() }
            Task { await backup.shutdown() }
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeOffPeakFixture(backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = OffPeakTarget.Context(
            config: OffPeakConfig(enabled: true, origin: "http://127.0.0.1:\(ticketPort)"),
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })

        let client = EmbeddedChannel()
        await forwardOffPeak(
            fixture, httpClient: httpClient, channel: client,
            bodyText: Self.offPeakBody(stream: true),
            offPeakContext: context, offPeakMonitor: WindowGateStub(open: true))

        // The client receives the ticket plane's SSE stream untouched.
        let (head, body, sawEnd) = try drainOffPeakResponse(client)
        #expect(head.status == .ok)
        #expect(
            (head.headers.first(name: "content-type") ?? "").lowercased()
                .contains("text/event-stream"))
        #expect(sawEnd)
        #expect(body == Data(Self.offPeakSSEFrames.utf8))

        // The data-plane request rode the rule's target model and the ticket.
        let dataPlane = try #require(ticketPlane.requests(at: OffPeakTarget.dataPlanePath).first)
        #expect(dataPlane.header("x-off-peak-ticket-id") == "tkt-fwd")
        #expect(dataPlane.jsonBody?["model"] as? String == "GLM-5.3")

        // Usage meters under the off-peak rule vendor, not the backup.
        let statsRecorded = await waitUntilOffPeak {
            fixture.tokenStatsStore.stats.records[fixture.offPeakVendorID] != nil
        }
        #expect(statsRecorded)
        let record = fixture.tokenStatsStore.stats.records[fixture.offPeakVendorID]?["GLM-5.3"]
        #expect(record?.inputTokens == 100)
        #expect(record?.outputTokens == 7)

        // Settle fired for the held ticket; the backup target stayed idle.
        let settled = await waitUntilOffPeak {
            !ticketPlane.requests(at: "/api/v1/off-peak/ticket/tkt-fwd/settle").isEmpty
        }
        #expect(settled)
        #expect(backup.recorded.isEmpty)
        _ = try? client.finish()
    }
}
