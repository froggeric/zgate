import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOHTTP1
import Testing
@testable import ZGate

/// Offline tests for `ApiKeyMinter` — the fallback-edge credential chain.
///
/// The api.z.ai biz family is served by a local SwiftNIO HTTP server
/// (127.0.0.1, ephemeral port) recording every request; the minter runs with
/// its default URLSession execute closure pointed at the stub through the
/// injectable origin. No real network, no real credential.
@Suite(.serialized)
struct ApiKeyMinterTests {

    // MARK: - Stub server (api.z.ai biz family)

    private final class BizStubServer: @unchecked Sendable {
        struct Recorded {
            let method: String
            let path: String
            let authorization: String?
            let body: Data?

            var jsonBody: [String: Any]? {
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            }
        }

        private let lock = NSRecursiveLock()
        private var _recorded: [Recorded] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?
        private var channels: [any Channel] = []
        /// Scripted responder: receives the recorded request, answers
        /// (status, body). Unset requests answer 404.
        var respond: ((Recorded) throws -> (Int, Data))?

        var recorded: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return _recorded
        }

        var paths: [String] { recorded.map(\.path) }

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(BizStubHandler(server: self))
                    }
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            lock.lock()
            serverChannel = channel
            lock.unlock()
            return channel.localAddress?.port ?? 0
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

        fileprivate func answer(for request: Recorded) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            guard let respond else { return (404, Data("{\"code\":404}".utf8)) }
            return (try? respond(request)) ?? (500, Data())
        }

        fileprivate func track(_ channel: any Channel) {
            lock.lock(); channels.append(channel); lock.unlock()
        }
    }

    private final class BizStubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: BizStubServer
        private var head: HTTPRequestHead?
        private var body = Data()

        init(server: BizStubServer) {
            self.server = server
        }

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
                let recorded = BizStubServer.Recorded(
                    method: head.method.rawValue,
                    path: head.uri,
                    authorization: head.headers.first(name: "authorization"),
                    body: body.isEmpty ? nil : body)
                server.record(recorded)
                let (status, payload) = server.answer(for: recorded)
                var responseHead = HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: status))
                responseHead.headers.add(name: "content-type", value: "application/json")
                responseHead.headers.add(name: "content-length", value: String(payload.count))
                let channel = context.channel
                channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                var buffer = channel.allocator.buffer(capacity: payload.count)
                buffer.writeBytes(payload)
                channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                self.head = nil
                body = Data()
            }
        }
    }

    // MARK: - Fixture payloads

    /// Two orgs; the 默认机构 org is SECOND and its 默认项目 project is
    /// SECOND — the selection rules must find both.
    private static let customerInfoJSON = """
        {"code":0,"data":{"organizations":[
        {"id":"org-first","name":"Personal","projects":[{"id":"proj-first","name":"Whatever"}]},
        {"id":"org-default","name":"默认机构","projects":[{"id":"proj-other","name":"Other"},{"id":"proj-default","name":"默认项目"}]}
        ]}}
        """
    private static var customerInfo: Data { Data(customerInfoJSON.utf8) }

    private static let keyList = Data(
        #"{"code":0,"data":{"list":[{"id":"ak-123","name":"zcode-api-key"},{"id":"ak-other","name":"manual key"}]}}"#.utf8)

    private static let emptyList = Data(#"{"code":0,"data":{"list":[]}}"#.utf8)
    private static let createdKey = Data(#"{"code":0,"data":{"id":"ak-new","name":"zcode-api-key"}}"#.utf8)
    private static let copyXYZ = Data(#"{"code":0,"data":{"secretKey":"sk-xyz"}}"#.utf8)
    private static let copyCreated = Data(#"{"code":0,"data":{"secretKey":"sk-created"}}"#.utf8)
    private static let copySnake = Data(#"{"code":0,"data":{"secret_key":"sk-snake"}}"#.utf8)
    private static let copyFirst = Data(#"{"code":0,"data":{"secretKey":"sk-first"}}"#.utf8)
    private static let copyNoSecret = Data(#"{"code":0,"data":{"apiKey":"ak-123"}}"#.utf8)
    private static let rejection = Data(#"{"code":401,"msg":"unauthorized"}"#.utf8)
    private static let noOrgs = Data(#"{"code":0,"data":{}}"#.utf8)

    private func minter(origin: String) -> ApiKeyMinter {
        var configuration = ApiKeyMinter.Configuration()
        configuration.origin = origin
        let token = "biz-jwt-token"
        configuration.bizJWTProvider = { token }
        return ApiKeyMinter(configuration: configuration)
    }

    private func minterWithoutProvider(origin: String) -> ApiKeyMinter {
        var configuration = ApiKeyMinter.Configuration()
        configuration.origin = origin
        return ApiKeyMinter(configuration: configuration)
    }

    /// Routes a recorded request through a path → payload table.
    private func respond(
        _ request: BizStubServer.Recorded,
        customerInfo: Data,
        keysList: Data,
        copyPayload: Data
    ) -> (Int, Data) {
        let path = request.path
        if path.contains("getCustomerInfo") {
            return (200, customerInfo)
        }
        if path.contains("/api_keys/copy/") {
            return (200, copyPayload)
        }
        if path.hasSuffix("/api_keys") {
            return (200, keysList)
        }
        return (404, Data())
    }

    // MARK: - Live wire shapes (regression, 2026-11-21)

    /// The REAL api.z.ai answers, byte-shaped as probed live: customer
    /// info keys orgs by `organizationId`/`projectId`; the api_keys LIST
    /// is `{"total":…, "data":[…]}` — no envelope code, data an ARRAY,
    /// entries keyed by `apiKey` with NO `id` field; copy answers the
    /// dict envelope with `secretKey`. Before the fix, `call()` threw
    /// `envelope(200, nil)` on the list step and the mint never completed
    /// (live symptom: off-peak status "missingCodingPlanKey").
    private static let liveCustomerInfo = Data("""
        {"code":200,"msg":"Operation successful","data":{"organizations":[
        {"organizationId":"org-live","organizationName":"默认机构","isDefault":true,
         "projects":[{"projectId":"proj-live","projectName":"默认项目","isDefault":true}]}
        ]}}
        """.utf8)

    private static let liveKeyList = Data(#"{"total":9,"data":[{"useApiKeyUserId":"u1","apiKey":"ak-hex-32-chars","secretKey":"*****masked","name":"zcode-api-key","isHidden":false,"keyType":1,"createTime":"2026-01-01"},{"apiKey":"ak-other","secretKey":"*****other","name":"Claude Code","isHidden":false}]}"#.utf8)

    private static let liveCopy = Data(#"{"code":200,"data":{"secretKey":"sk-live"}}"#.utf8)

    @Test func mintAgainstTheLiveWireShapes() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { [self] request in
            respond(request, customerInfo: Self.liveCustomerInfo, keysList: Self.liveKeyList, copyPayload: Self.liveCopy)
        }

        let credential = try await minter(origin: "http://127.0.0.1:\(port)").mint()

        // The named live entry is found by `apiKey` (no id field) and the
        // copy reveal assembles `{apiKey}.{secretKey}`.
        #expect(credential == "ak-hex-32-chars.sk-live")
        #expect(stub.paths == [
            "/api/biz/customer/getCustomerInfo",
            "/api/biz/v1/organization/org-live/projects/proj-live/api_keys",
            "/api/biz/v1/organization/org-live/projects/proj-live/api_keys/copy/ak-hex-32-chars",
        ])
        // The named key exists — no create POST.
        #expect(stub.recorded.allSatisfy { $0.method == "GET" })
    }

    // MARK: - Happy path

    @Test func mintSelectsDefaultOrgAndProjectAndBuildsCredential() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { [self] request in
            respond(request, customerInfo: Self.customerInfo, keysList: Self.keyList, copyPayload: Self.copyXYZ)
        }

        let credential = try await minter(origin: "http://127.0.0.1:\(port)").mint()

        #expect(credential == "ak-123.sk-xyz")
        // Exactly the chain, no create: info → list → copy, all GET.
        #expect(stub.paths == [
            "/api/biz/customer/getCustomerInfo",
            "/api/biz/v1/organization/org-default/projects/proj-default/api_keys",
            "/api/biz/v1/organization/org-default/projects/proj-default/api_keys/copy/ak-123",
        ])
        #expect(stub.recorded.allSatisfy { $0.method == "GET" })
        // Every call rides the biz JWT.
        #expect(stub.recorded.allSatisfy { $0.authorization == "Bearer biz-jwt-token" })
    }

    @Test func mintCreatesTheKeyWhenMissingThenCopiesIt() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            let path = request.path
            if path.contains("getCustomerInfo") {
                return (200, Self.customerInfo)
            }
            if path.contains("/api_keys/copy/ak-new") {
                return (200, Self.copyCreated)
            }
            if path.hasSuffix("/api_keys") && request.method == "POST" {
                return (200, Self.createdKey)
            }
            if path.hasSuffix("/api_keys") {
                return (200, Self.emptyList)
            }
            return (404, Data())
        }

        let credential = try await minter(origin: "http://127.0.0.1:\(port)").mint()

        #expect(credential == "ak-new.sk-created")
        // The create POST carries the pinned name in its body.
        let create = try #require(stub.recorded.first { $0.method == "POST" })
        #expect(create.path.hasSuffix("/api_keys"))
        #expect(create.jsonBody?["name"] as? String == "zcode-api-key")
        #expect(create.jsonBody?.count == 1)
        // List was consulted before the create.
        #expect(stub.recorded.map(\.method) == ["GET", "GET", "POST", "GET"])
    }

    @Test func mintAcceptsSnakeCaseSecretKeyField() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { [self] request in
            respond(request, customerInfo: Self.customerInfo, keysList: Self.keyList, copyPayload: Self.copySnake)
        }

        #expect(try await minter(origin: "http://127.0.0.1:\(port)").mint() == "ak-123.sk-snake")
    }

    @Test func mintUsesFirstOrgAndProjectWhenNoDefaultNamesExist() async throws {
        let unnamedOrgsJSON = """
            {"code":0,"data":{"organizations":[
            {"id":"org-a","name":"Alpha","projects":[{"id":"proj-a","name":"Alpha project"}]}
            ]}}
            """
        let unnamedOrgs = Data(unnamedOrgsJSON.utf8)
        let firstKeyList = Data(
            #"{"code":0,"data":{"list":[{"id":"ak-first","name":"zcode-api-key"}]}}"#.utf8)
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            respond(request, customerInfo: unnamedOrgs, keysList: firstKeyList, copyPayload: Self.copyFirst)
        }

        let credential = try await minter(origin: "http://127.0.0.1:\(port)").mint()

        #expect(credential == "ak-first.sk-first")
        #expect(stub.paths.contains(
            "/api/biz/v1/organization/org-a/projects/proj-a/api_keys"))
    }

    // MARK: - Failures

    @Test func mintThrowsWhenCopyLacksASecret() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { [self] request in
            respond(request, customerInfo: Self.customerInfo, keysList: Self.keyList, copyPayload: Self.copyNoSecret)
        }

        await #expect(throws: ApiKeyMinter.MintError.missingSecretKey) {
            _ = try await minter(origin: "http://127.0.0.1:\(port)").mint()
        }
    }

    @Test func mintThrowsOnBusinessRejection() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let payload = Self.rejection
        stub.respond = { _ in (200, payload) }

        await #expect(throws: ApiKeyMinter.MintError.envelope(status: 200, code: 401)) {
            _ = try await minter(origin: "http://127.0.0.1:\(port)").mint()
        }
        #expect(stub.recorded.count == 1)  // fails on the first call, no retry
    }

    @Test func mintThrowsOnMalformedCustomerInfo() async throws {
        let stub = BizStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let payload = Self.noOrgs
        stub.respond = { _ in (200, payload) }

        await #expect(throws: ApiKeyMinter.MintError.self) {
            _ = try await minter(origin: "http://127.0.0.1:\(port)").mint()
        }
    }

    @Test func mintThrowsWithoutABizJWTProvider() async {
        let theMinter = minterWithoutProvider(origin: "http://127.0.0.1:1")
        await #expect(throws: ApiKeyMinter.MintError.noBizJWT) {
            _ = try await theMinter.mint()
        }
    }

    // MARK: - Edge identification

    @Test func fallbackEdgeIdentification() {
        #expect(ApiKeyMinter.isFallbackEdge("https://api.z.ai/api/anthropic"))
        #expect(ApiKeyMinter.isFallbackEdge("https://api.z.ai/api/anthropic/"))
        #expect(ApiKeyMinter.isFallbackEdge("HTTPS://API.Z.AI/API/ANTHROPIC"))
        #expect(!ApiKeyMinter.isFallbackEdge("https://api.z.ai/api/paas/v4"))
        #expect(!ApiKeyMinter.isFallbackEdge("http://127.0.0.1:8123"))
        #expect(!ApiKeyMinter.isFallbackEdge("https://zcode.z.ai/api/v1/zcode-plan/anthropic"))
    }
}
