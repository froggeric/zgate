import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Offline tests for `OffPeakTicketClient` — the Off-Peak / Idle Plan
/// ticket-queue control plane (availability / take / status / settle).
///
/// The plane is served by a local SwiftNIO stub (127.0.0.1, ephemeral port)
/// recording every request; the client runs with its DEFAULT execute closure
/// (a real AsyncHTTPClient) pointed at the stub through the injectable
/// origin, so the whole-exchange path is the production one. One test
/// additionally injects an execute closure to pin the per-call timeout
/// discipline. No real network, no real credential.
struct OffPeakTicketClientTests {

    // MARK: - Stub server (zcode.z.ai off-peak plane)

    private final class TicketStubServer: @unchecked Sendable {
        struct Recorded {
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data?

            var jsonBody: [String: Any]? {
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            }

            func header(_ name: String) -> String? {
                headers[name.lowercased()]
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
                        channel.pipeline.addHandler(TicketStubHandler(server: self))
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

    private final class TicketStubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: TicketStubServer
        private var head: HTTPRequestHead?
        private var body = Data()

        init(server: TicketStubServer) {
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
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                let recorded = TicketStubServer.Recorded(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: headers,
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

    private static let availabilityTrue =
        Data(#"{"code":0,"data":{"can_take_number":true}}"#.utf8)
    private static let availabilityFalse = Data(
        #"{"code":0,"data":{"can_take_number":false,"next_take_at":1763001200}}"#.utf8)
    private static let availabilityFalseNoNext =
        Data(#"{"code":0,"data":{"can_take_number":false}}"#.utf8)
    private static let takeReady = Data(
        #"{"code":0,"data":{"ticket_id":"tkt-1","state":"ready","position":3,"active_deadline":1763001200,"next_poll_after":30}}"#
            .utf8)
    private static let statusBatch = Data(
        #"{"code":0,"data":{"tickets":[{"ticket_id":"tkt-1","state":"queued","position":5},{"ticket_id":"tkt-2","state":"active"},{"ticket_id":"tkt-3","state":"not_found"}],"next_poll_after":15}}"#
            .utf8)
    private static let rejection = Data(#"{"code":42,"msg":"nope"}"#.utf8)
    private static let settleAck = Data(#"{"code":0,"data":{}}"#.utf8)
    private static let settleNotFound = Data(#"{"code":4040104,"msg":"ticket not found"}"#.utf8)

    // MARK: - Helpers

    private func makeClient(origin: String) -> OffPeakTicketClient {
        OffPeakTicketClient(
            origin: origin,
            jwtProvider: { "zcode-plan-jwt" },
            credentialProvider: { "ak-123.sk-xyz" })
    }

    /// Lock-guarded recorder for the injected-execute timeout test.
    private final class ExecuteRecorder: @unchecked Sendable {
        struct Entry {
            let method: String
            let url: String
            let timeout: TimeInterval
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []

        var entries: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return _entries
        }

        func record(_ entry: Entry) {
            lock.lock(); _entries.append(entry); lock.unlock()
        }
    }

    // MARK: - Availability

    @Test func availabilityParsesTrueAndRidesUnsignedIdentityFace() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.availabilityTrue) }

        let availability = try await makeClient(origin: "http://127.0.0.1:\(port)").availability()

        #expect(availability.canTake)
        #expect(availability.nextTakeAtSeconds == nil)
        #expect(stub.paths == ["/api/v1/off-peak/ticket/availability"])
        let request = try #require(stub.recorded.first)
        #expect(request.method == "GET")
        // Both auth headers on EVERY call.
        #expect(request.header("authorization") == "Bearer zcode-plan-jwt")
        #expect(request.header("x-coding-plan-api-key") == "ak-123.sk-xyz")
        // Identity face pinned from the relay's CLI 0.17.1 set.
        #expect(request.header("user-agent") == "ZCode/0.17.1 ai-sdk/anthropic/3.0.81")
        #expect(request.header("x-zcode-app-version") == "0.17.1")
        #expect(request.header("http-referer") == "https://zcode.z.ai")
        #expect(request.header("x-title") == "Z Code@cli")
        #expect(request.header("x-client-language") == "en-US")
        #expect(request.header("x-zcode-agent") == "glm")
        #expect(request.header("x-platform") == RelayTarget.platform)
        #expect(request.header("x-os-category") == "macos")
        #expect(request.header("x-os-version") == RelayTarget.osVersion)
        #expect(request.header("x-zcode-session-type") == "main")
        #expect(request.header("x-zcode-query-source") == "main_turn")
        #expect(!(request.header("x-session-id") ?? "").isEmpty)
        #expect(!(request.header("x-request-id") ?? "").isEmpty)
        // NEVER signed: the V4 quartet and the signed-plane identity markers
        // are all absent on the off-peak plane.
        for unsigned in [
            "x-client-ts", "x-client-sig", "x-client-nonce", "x-client-pow", "x-app-id", "x-api-key",
        ] {
            #expect(request.header(unsigned) == nil, "off-peak plane must not carry \(unsigned)")
        }
        // A GET without a body carries no content-type.
        #expect(request.header("content-type") == nil)
    }

    @Test func availabilityFalseCarriesNextTakeAtUnixSeconds() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.availabilityFalse) }

        let availability = try await makeClient(origin: "http://127.0.0.1:\(port)").availability()

        #expect(availability.canTake == false)
        // Pinned as UNIX SECONDS — no millisecond conversion on this field.
        #expect(availability.nextTakeAtSeconds == 1_763_001_200)
    }

    @Test func availabilityFalseWithoutNextTakeAtIsMalformed() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.availabilityFalseNoNext) }

        await #expect(throws: OffPeakTicketError.malformed("availability false without next_take_at")) {
            try await makeClient(origin: "http://127.0.0.1:\(port)").availability()
        }
    }

    // MARK: - Take

    @Test func takeTicketPostsTaskIDAndConvertsDeadlineToMilliseconds() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.takeReady) }

        let ticket = try await makeClient(origin: "http://127.0.0.1:\(port)").takeTicket(taskID: "zgate-task-1")

        #expect(ticket == OffPeakTicket(
            ticketID: "tkt-1",
            state: .ready,
            position: 3,
            activeDeadlineMs: 1_763_001_200_000,
            nextPollAfterSeconds: 30))
        let request = try #require(stub.recorded.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/off-peak/ticket")
        #expect(request.jsonBody?["task_id"] as? String == "zgate-task-1")
        #expect(request.jsonBody?.count == 1)
        #expect(request.header("content-type") == "application/json")
        // The take call rides the same unsigned auth pair.
        #expect(request.header("authorization") == "Bearer zcode-plan-jwt")
        #expect(request.header("x-coding-plan-api-key") == "ak-123.sk-xyz")
        #expect(request.header("x-client-sig") == nil)
    }

    // MARK: - Status

    @Test func statusPostsIDBatchAndParsesTicketsAndNextPoll() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.statusBatch) }

        let result = try await makeClient(origin: "http://127.0.0.1:\(port)")
            .status(ticketIDs: ["tkt-1", "tkt-2"])

        #expect(result.tickets == [
            OffPeakTicket(ticketID: "tkt-1", state: .queued, position: 5, activeDeadlineMs: nil, nextPollAfterSeconds: nil),
            OffPeakTicket(ticketID: "tkt-2", state: .active, position: nil, activeDeadlineMs: nil, nextPollAfterSeconds: nil),
            OffPeakTicket(ticketID: "tkt-3", state: .notFound, position: nil, activeDeadlineMs: nil, nextPollAfterSeconds: nil),
        ])
        #expect(result.nextPollAfterSeconds == 15)
        let request = try #require(stub.recorded.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/off-peak/ticket/status")
        #expect(request.jsonBody?["ticket_ids"] as? [String] == ["tkt-1", "tkt-2"])
    }

    @Test func statusSplits101IDsIntoTwoBatchesOf100And1() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        // Each batch is answered with one queued row per requested id; the
        // first batch's next_poll_after (15 s) is larger than the second's
        // (10 s) so the max-aggregation across batches is pinned.
        stub.respond = { request in
            let ids = (request.jsonBody?["ticket_ids"] as? [String]) ?? []
            let rows: [[String: Any]] = ids.map { ["ticket_id": $0, "state": "queued"] }
            let nextPoll: Int = ids.count > 1 ? 15 : 10
            let envelope: [String: Any] = [
                "code": 0, "data": ["tickets": rows, "next_poll_after": nextPoll]
            ]
            return (200, try JSONSerialization.data(withJSONObject: envelope))
        }

        let ids = (0...100).map { "id-\($0)" }
        let result = try await makeClient(origin: "http://127.0.0.1:\(port)").status(ticketIDs: ids)

        let statusRequests = stub.recorded.filter { $0.path == "/api/v1/off-peak/ticket/status" }
        #expect(statusRequests.count == 2)
        #expect(statusRequests.allSatisfy { $0.method == "POST" })
        let firstBatch = try #require(statusRequests.first?.jsonBody?["ticket_ids"] as? [String])
        let secondBatch = try #require(statusRequests.last?.jsonBody?["ticket_ids"] as? [String])
        #expect(firstBatch.count == 100)
        #expect(firstBatch == Array(ids.prefix(100)))
        #expect(secondBatch == ["id-100"])
        // Tickets from BOTH batches come back in order.
        #expect(result.tickets.map(\.ticketID) == ids)
        #expect(result.tickets.allSatisfy { $0.state == .queued })
        // The larger batch hint wins.
        #expect(result.nextPollAfterSeconds == 15)
    }

    // MARK: - Envelope discipline

    @Test func nonZeroEnvelopeCodeThrowsTypedErrorWithCodeAndMessage() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Self.rejection) }

        await #expect(throws: OffPeakTicketError.envelope(status: 200, code: 42, msg: "nope")) {
            try await makeClient(origin: "http://127.0.0.1:\(port)").availability()
        }
    }

    @Test func unparseableBodyThrowsEnvelopeWithoutCode() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (200, Data("not json".utf8)) }

        await #expect(throws: OffPeakTicketError.envelope(status: 200, code: nil, msg: nil)) {
            try await makeClient(origin: "http://127.0.0.1:\(port)").availability()
        }
    }

    // MARK: - Settle

    @Test func settleTreats4xxAsSuccess() async throws {
        let stub = TicketStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in (404, Self.settleNotFound) }

        // "Never throws" — the 404 path returns normally.
        await makeClient(origin: "http://127.0.0.1:\(port)").settle(ticketID: "tkt-9")

        let request = try #require(stub.recorded.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/off-peak/ticket/tkt-9/settle")
        // No body on settle.
        #expect(request.body == nil)
        #expect(request.header("authorization") == "Bearer zcode-plan-jwt")
        #expect(request.header("x-coding-plan-api-key") == "ak-123.sk-xyz")
    }

    @Test func settleNeverThrowsOnTransportFailure() async throws {
        // A transport-level failure from the execute seam (connection
        // refused / dropped) is swallowed like every other settle failure.
        // Injected rather than a closed loopback port: on hosts where the
        // firewall drops instead of rejecting, a real dropped-SYN connect
        // makes the test crawl (the swallow property is identical).
        let client = OffPeakTicketClient(
            origin: "https://zcode.z.ai",
            jwtProvider: { "zcode-plan-jwt" },
            credentialProvider: { "ak-123.sk-xyz" },
            execute: { _, _, _ in throw HTTPClientError.connectTimeout })

        await client.settle(ticketID: "tkt-9")
    }

    // MARK: - Timeout discipline (injected execute)

    @Test func executeReceivesCallSpecificWholeExchangeTimeouts() async throws {
        let recorder = ExecuteRecorder()
        // One envelope whose data satisfies every parser (availability, one
        // ticket row, and a tickets array) — the assertions are about the
        // requests, not the responses.
        let universal = Data(
            #"{"code":0,"data":{"can_take_number":true,"ticket_id":"tkt-x","state":"queued","position":1,"active_deadline":100,"next_poll_after":1,"tickets":[{"ticket_id":"tkt-x","state":"queued"}]}}"#
                .utf8)
        let client = OffPeakTicketClient(
            origin: "https://zcode.z.ai",
            jwtProvider: { "zcode-plan-jwt" },
            credentialProvider: { "ak-123.sk-xyz" },
            execute: { request, _, timeout in
                recorder.record(ExecuteRecorder.Entry(
                    method: request.method.rawValue,
                    url: request.url,
                    timeout: timeout))
                return (200, universal)
            })

        _ = try await client.availability()
        _ = try await client.takeTicket(taskID: "zgate-task-1")
        _ = try await client.status(ticketIDs: ["tkt-1"])
        await client.settle(ticketID: "tkt-1")

        let entries = recorder.entries
        #expect(entries.map(\.timeout) == [
            OffPeakTicketClient.requestTimeout,
            OffPeakTicketClient.requestTimeout,
            OffPeakTicketClient.requestTimeout,
            OffPeakTicketClient.settleTimeout,
        ])
        #expect(entries.map(\.method) == ["GET", "POST", "POST", "POST"])
        #expect(entries.map(\.url) == [
            "https://zcode.z.ai/api/v1/off-peak/ticket/availability",
            "https://zcode.z.ai/api/v1/off-peak/ticket",
            "https://zcode.z.ai/api/v1/off-peak/ticket/status",
            "https://zcode.z.ai/api/v1/off-peak/ticket/tkt-1/settle",
        ])
        #expect(OffPeakTicketClient.requestTimeout == 15)
        #expect(OffPeakTicketClient.settleTimeout == 8)
    }
}
