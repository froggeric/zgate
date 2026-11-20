import Foundation
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import AsyncHTTPClient
import OSLog

/// Async forwarding logic, called from a Task inside ProxyChannelHandler.
enum ProxyForwarder {
    static let maxBranchWaitAttempts = 3

    struct BranchWaitBudget: Sendable, Equatable {
        let maxAttempts: Int
        private(set) var attempts: Int = 0

        init(maxAttempts: Int = ProxyForwarder.maxBranchWaitAttempts) {
            self.maxAttempts = maxAttempts
        }

        mutating func recordWait() -> Bool {
            attempts += 1
            return attempts <= maxAttempts
        }
    }

    static func forward(
        clientName: String,
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        router: RequestRouter,
        httpClient: HTTPClient,
        trafficLog: TrafficLog,
        tokenStatsStore: TokenStatsStore,
        lineageBroker: any SessionLineageBrokering,
        portableNormalizer: any PortableContentNormalizing,
        requestCoordinator: any BranchRequestCoordinating,
        webSearchProvider: (any WebSearchBridgeProviding)?,
        webSearchForwardAsIs: Bool = false,
        relayContext: RelayTarget.Context? = nil,
        localHealth: LocalHealthMonitor? = nil,
        offPeakContext: OffPeakTarget.Context? = nil,
        offPeakMonitor: (any OffPeakAvailabilityMonitoring)? = nil
    ) async {
        let requestID = String(UUID().uuidString.prefix(8))
        let startTime = Date.now

        // 0. Connection probes carry no model to route by; answer them without touching upstreams.
        if Self.isLocalProbe(head) {
            await Self.sendResponse(channel: channel, status: .ok, contentType: nil, body: Data())
            return
        }

        let requestKind = requestKind(for: head.uri)
        let originalBodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()
        let requestScopes = requestScopeKeys(
            bodyData: originalBodyData,
            headers: head.headers,
            clientName: clientName,
            channel: channel
        )
        let requestClass = Self.claudeCodeRequestClass(from: head.headers)

        // 1. Extract original API key (support both x-api-key and Authorization: Bearer).
        let originalAPIKey = Self.extractAPIKey(from: head.headers)

        // 2. Resolve route.
        let resolveResult: RoutingSnapshot.ResolveResult
        let model: String
        var routeState: RoutingSnapshot.RouteState
        do {
            (resolveResult, model, routeState) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
        } catch {
            await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
            return
        }

        let resolvedTarget: RoutingSnapshot.RouteTarget
        switch resolveResult {
        case .routed(let t):
            resolvedTarget = t
        case .blocked(let reason):
            AppLog.proxy.info("[Proxy] [\(requestID)] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
            let blockedEntry = TrafficEntry(
                model: model,
                routeType: .blocked,
                requestKind: .blocked,
                httpStatus: 403
            )
            await MainActor.run { trafficLog.append(blockedEntry.with(requestClass: requestClass)) }
            await Self.sendError(channel: channel, status: .forbidden, message: reason)
            return
        }

        let target = resolvedTarget
        if Self.answersCountTokensLocally(requestKind: requestKind, target: target) {
            // Token counting is optional for Claude Code: on a 404 it falls back to a local estimate.
            // Never answer 501 here; Claude Code turns a 501 into a real one-token generation request.
            AppLog.proxy.info(
                "[Proxy] [\(requestID)] count_tokens unsupported by vendor=\(target.vendorName); answered 404 locally"
            )
            await Self.sendResponse(
                channel: channel,
                status: .notFound,
                contentType: "application/json",
                body: Self.countTokensUnsupportedBody(vendorName: target.vendorName)
            )
            let entry = TrafficEntry(
                model: model,
                routeType: .mapped(targetModel: target.targetModel ?? model),
                requestKind: .countTokens,
                httpStatus: 404,
                duration: Date.now.timeIntervalSince(startTime)
            )
            await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
            return
        }

        // Log request routing (no API keys or body content).
        let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
        let originalCL = head.headers.first(name: "content-length") ?? "absent"
        let hasThinking = Self.containsJSONStringField(originalBodyData, field: "thinking")
        let hasSignature = Self.containsJSONStringField(originalBodyData, field: "signature")
        AppLog.proxy.info(
            "[Proxy] [\(requestID)] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL) body=\(originalBodyData.count)B cl=\(originalCL) thinking=\(hasThinking) signature=\(hasSignature)"
        )

        // 3b. Diagnostic logging for thinking/signature investigation (debug mode only).
        if hasThinking || hasSignature {
            let debugEnabled = await MainActor.run { AppLogManager.shared.isEnabled }
            if debugEnabled {
                Self.logThinkingDiagnostics(body: originalBodyData, requestID: requestID)
            }
        }

        let initialPreparedRequest: PreparedRequest
        do {
            initialPreparedRequest = try await lineageBroker.prepareRequest(
                bodyData: originalBodyData,
                clientName: clientName,
                sessionScopeKey: requestScopes.sessionScopeKey,
                coordinationScopeKey: requestScopes.coordinationScopeKey,
                target: target
            )
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Lineage prepare failed: \(error)")
            await Self.sendError(channel: channel, status: .badRequest, message: "Request projection failed: \(error)")
            return
        }

        let debugEnabled = await MainActor.run { AppLogManager.shared.isEnabled }
        if debugEnabled {
            Self.logProjectionDiagnostics(
                requestID: requestID,
                originalBody: originalBodyData,
                preparedRequest: initialPreparedRequest
            )
        }

        var preparedRequest = initialPreparedRequest
        // Local (splash) targets and off-peak ticket-plane targets skip
        // branch coordination: both serve through a channel-writing core
        // with no replayable capture (a cut ends in a terminal error event),
        // and a queued off-peak ticket may legitimately hold for minutes —
        // an in-flight lease held across that would stall same-scope
        // retries. The projector's vendor-ready body above still applies;
        // dropping the context only opts these routes out of in-flight
        // dedup/replay/commit.
        if LocalTarget.isLocalTarget(target) || target.vendorKind == .offPeak {
            preparedRequest = PreparedRequest(
                bodyData: preparedRequest.bodyData,
                context: nil,
                projectedPortableMessagesData: nil)
        }
        var branchLease: BranchRequestLease?
        var waitBudget = BranchWaitBudget()
        while let context = preparedRequest.context {
            let decision = await requestCoordinator.acquire(context: context)
            if debugEnabled {
                Self.logCoordinatorDiagnostics(requestID: requestID, decision: decision, context: context)
            }
            switch decision {
            case .acquired(let lease):
                branchLease = lease
                break
            case .replay(let cachedResponse, _):
                // This path never owns a lease; the leader completed the in-flight entry and handed
                // followers a cached response directly.
                await ResponseRelay.replay(
                    cachedResponse: cachedResponse,
                    to: channel,
                    requestID: requestID
                )
                let duration = Date.now.timeIntervalSince(startTime)
                let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: target.targetModel ?? model)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: cachedResponse.trafficRequestKind ?? requestKind,
                    httpStatus: cachedResponse.statusCode,
                    duration: duration
                )
                await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
                return
            case .waited:
                // This path also does not own a lease. It only waits for the leader to finish, then
                // reprojection decides whether committed branch history can be reused.
                let shouldContinue = waitBudget.recordWait()
                if !shouldContinue {
                    AppLog.proxy.error(
                        "[Proxy] [\(requestID)] CoordinatorDiag: action=aborted reason=max_wait_attempts limit=\(waitBudget.maxAttempts) lineage=\(context.lineageKey) branch=\(context.branchKey) hashes=\(context.preparedPortableMessageHashes.count)"
                    )
                    await Self.sendError(
                        channel: channel,
                        status: .conflict,
                        message: "Branch request coordination exceeded max wait attempts (\(waitBudget.maxAttempts))"
                    )
                    return
                }
                do {
                    preparedRequest = try await lineageBroker.prepareRequest(
                        bodyData: originalBodyData,
                        clientName: clientName,
                        sessionScopeKey: requestScopes.sessionScopeKey,
                        coordinationScopeKey: requestScopes.coordinationScopeKey,
                        target: target
                    )
                } catch {
                    AppLog.proxy.error("[Proxy] [\(requestID)] Lineage reprepare failed: \(error)")
                    await Self.sendError(channel: channel, status: .badRequest, message: "Request reprojection failed: \(error)")
                    return
                }
                if debugEnabled {
                    Self.logProjectionDiagnostics(
                        requestID: requestID,
                        originalBody: originalBodyData,
                        preparedRequest: preparedRequest
                    )
                }
                continue
            case .leaderFailed(let source, let replay):
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] CoordinatorDiag: action=leader_failed sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count) status=\(replay?.statusCode ?? 0)"
                )
                if let replay {
                    await ResponseRelay.replay(
                        cachedResponse: replay,
                        to: channel,
                        requestID: requestID
                    )
                    let duration = Date.now.timeIntervalSince(startTime)
                    let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                        ? .passthrough
                        : .mapped(targetModel: target.targetModel ?? model)
                    let entry = TrafficEntry(
                        model: model,
                        routeType: entryRouteType,
                        requestKind: replay.trafficRequestKind ?? requestKind,
                        httpStatus: replay.statusCode,
                        duration: duration
                    )
                    await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
                } else {
                    await Self.sendError(
                        channel: channel,
                        status: .conflict,
                        message: "Prior branch request failed before committing vendor history"
                    )
                    let duration = Date.now.timeIntervalSince(startTime)
                    let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                        ? .passthrough
                        : .mapped(targetModel: target.targetModel ?? model)
                    let entry = TrafficEntry(
                        model: model,
                        routeType: entryRouteType,
                        requestKind: requestKind,
                        httpStatus: 409,
                        duration: duration
                    )
                    await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
                }
                return
            }
            break
        }

        if let context = preparedRequest.context, context.reusedBranchHistory {
            // Claude Code already receives and resends vendor thinking, so branch replay only adds
            // value when it restores thinking the client no longer sends. Logged (counts only) to
            // decide whether the replay machinery can be retired.
            let restored = Self.restoredThinkingBlockCount(
                originalBody: originalBodyData,
                preparedBody: preparedRequest.bodyData
            )
            if restored > 0 {
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] BranchReplay restored thinking blocks=\(restored) vendor=\(target.vendorName) branch=\(context.branchKey)"
                )
            }
        }

        if target.signingDomain.supportsAnthropicSignedReplay {
            let sanitized = sanitizeAnthropicBodyIfNeeded(preparedRequest.bodyData)
            preparedRequest = PreparedRequest(
                bodyData: sanitized.bodyData,
                context: preparedRequest.context,
                projectedPortableMessagesData: preparedRequest.projectedPortableMessagesData
            )
            if sanitized.normalizedToolUseCount > 0 || sanitized.normalizedToolResultCount > 0 {
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] ToolIDGuard: normalized outbound Anthropic transcript tool_use=\(sanitized.normalizedToolUseCount) tool_result=\(sanitized.normalizedToolResultCount)"
                )
            }
        }

        if let webSearchProvider,
           WebSearchBridge.shouldHandle(
            bodyData: preparedRequest.bodyData,
            target: target,
            requestKind: requestKind
        ) {
            nonisolated(unsafe) var lastBridgeTarget: RoutingSnapshot.RouteTarget?
            do {
                let bridgeResult = try await WebSearchBridge.execute(
                    bodyData: preparedRequest.bodyData,
                    httpClient: httpClient,
                    portableNormalizer: portableNormalizer,
                    provider: webSearchProvider,
                    performModelTurn: { turnBodyData in
                        let (bridgeResponse, usedBridgeTarget) = await Self.executeWithFailover(
                            head: head,
                            bodyData: turnBodyData,
                            primaryTarget: target,
                            model: model,
                            router: router,
                            httpClient: httpClient,
                            routeState: &routeState,
                            requestID: requestID
                        )
                        guard let bridgeResponse, let usedBridgeTarget else {
                            throw WebSearchBridgeError.upstreamFailure(statusCode: 502, bodyPreview: "Upstream unreachable")
                        }
                        lastBridgeTarget = usedBridgeTarget
                        return WebSearchBridge.ModelResponse(
                            statusCode: Int(bridgeResponse.status.code),
                            headers: bridgeResponse.headers.map { ($0.name, $0.value) },
                            bodyData: try await Self.collectResponseBody(bridgeResponse)
                        )
                    }
                )
                await router.updateRouteState(model: model, state: routeState)

                let usedTarget = lastBridgeTarget ?? target
                let statsModel = usedTarget.targetModel ?? model
                let entryRouteType: TrafficEntry.RouteType = usedTarget.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: usedTarget.targetModel ?? model)
                let sourceModelForStats: String? = usedTarget.isPassthrough ? nil : model
                if let vendorID = usedTarget.vendorID {
                    await MainActor.run {
                        tokenStatsStore.add(
                            vendorID: vendorID,
                            model: statsModel,
                            input: bridgeResult.inputTokens,
                            output: bridgeResult.outputTokens,
                            sourceModel: sourceModelForStats
                        )
                    }
                }

                AppLog.proxy.debug(
                    "[Proxy] [\(requestID)] Response: 200 OK model=\(model) vendor=\(usedTarget.vendorName) bridge=web_search"
                )
                await ResponseRelay.replay(
                    cachedResponse: bridgeResult.clientResponse,
                    to: channel,
                    requestID: requestID
                )
                if let branchContext = preparedRequest.context,
                   let branchLease,
                   let assistantTurn = bridgeResult.assistantTurn {
                    await Self.commitBridgeAssistantTurnIfCurrent(
                        assistantTurn,
                        branchContext: branchContext,
                        branchLease: branchLease,
                        lineageBroker: lineageBroker,
                        requestCoordinator: requestCoordinator,
                        requestID: requestID
                    )
                    await requestCoordinator.complete(lease: branchLease, replay: bridgeResult.clientResponse)
                } else if let branchLease {
                    await requestCoordinator.complete(lease: branchLease, replay: bridgeResult.clientResponse)
                }

                let duration = Date.now.timeIntervalSince(startTime)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: .webSearchBridge(searchCount: bridgeResult.webSearchRequestCount),
                    httpStatus: 200,
                    duration: duration,
                    outputTokens: bridgeResult.outputTokens
                )
                await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
                return
            } catch {
                await router.updateRouteState(model: model, state: routeState)
                if let branchLease {
                    await requestCoordinator.complete(lease: branchLease, replay: nil)
                }
                AppLog.proxy.error("[Proxy] [\(requestID)] WebSearch bridge failed: \(String(describing: error))")
                let duration = Date.now.timeIntervalSince(startTime)
                let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: target.targetModel ?? model)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: .webSearchBridge(searchCount: 0),
                    httpStatus: 502,
                    duration: duration
                )
                await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
                await Self.sendError(channel: channel, status: .badGateway, message: "WebSearch bridge failed: \(error)")
                return
            }
        }

        // 3b. Sanitize tools for mapped vendors (always, regardless of web search config).
        // WebSearchBridge handles web_search_* tools separately; this catches other
        // vendor-incompatible tools (empty name, missing input_schema, server-side types).
        // Relay targets are exempt: the body stays byte-identical except the
        // model rewrite (zbridge parity).
        var forwardBodyData = preparedRequest.bodyData
        if !target.isPassthrough && target.vendorKind != .relay {
            forwardBodyData = Self.sanitizeToolsForVendor(in: forwardBodyData)
        }
        let toolCatalog = ToolCallInputGuard.ToolCatalog.fromRequestBody(forwardBodyData)

        // 4. Build and send upstream request. Off-peak rule targets gate onto
        // the ticket plane (Task 4) — every gate failure serves the rule's
        // backup instead (the cardinal rule: a routed request must never
        // answer async_stream_required or silently wait in the queue).
        // Relay-kind rules run the signed ladder (RelayTarget): cold starts
        // wait for the handshake, 401s walk the reject ladder, 429s retry
        // once then fall back / answer 529. Local (splash) targets run
        // LocalTarget's ladder: credential-free passthrough, 5xx/transport
        // fallback over the rule's targets, and a cut-protected stream
        // relay.
        var relayTerminal: RelayTarget.UpstreamTerminal? = nil
        let upstreamResponse: HTTPClientResponse?
        let usedTarget: RoutingSnapshot.RouteTarget?
        let streamsViaLocalRelay: Bool
        if target.vendorKind == .offPeak {
            // Gates — all cached/local reads, never a request-time
            // availability call on the hot path: surface enabled ∧ window
            // open (polled monitor) ∧ the request opted into streaming.
            let surfaceEnabled = offPeakContext?.configuration().enabled ?? false
            let windowOpen = offPeakMonitor?.isWindowOpen ?? false
            if let offPeakContext, surfaceEnabled, windowOpen, Self.requestIsStream(forwardBodyData) {
                await OffPeakTarget.serve(
                    head: head,
                    body: ByteBuffer(data: forwardBodyData),
                    channel: channel,
                    context: offPeakContext,
                    targetModel: target.targetModel,
                    trafficLog: trafficLog,
                    tokenStatsStore: tokenStatsStore,
                    vendorID: target.vendorID,
                    requestID: requestID)
                // serve owns the client channel (the LocalTarget contract):
                // its own traffic row and token stats were recorded, and the
                // branch context was dropped for this route kind above.
                return
            }
            let failedGate = !surfaceEnabled
                ? "surface disabled"
                : (!windowOpen ? "window closed" : "non-streaming request")
            (upstreamResponse, usedTarget, relayTerminal) = await Self.serveOffPeakFallback(
                head: head,
                bodyData: forwardBodyData,
                primaryTarget: target,
                model: model,
                router: router,
                httpClient: httpClient,
                routeState: &routeState,
                requestID: requestID,
                relayContext: relayContext,
                failedGate: failedGate)
            streamsViaLocalRelay = false
        } else if target.vendorKind == .relay {
            (upstreamResponse, usedTarget, relayTerminal) = await Self.executeRelay(
                head: head,
                bodyData: forwardBodyData,
                primaryTarget: target,
                model: model,
                router: router,
                httpClient: httpClient,
                routeState: &routeState,
                requestID: requestID,
                relayContext: relayContext
            )
            streamsViaLocalRelay = false
        } else if LocalTarget.isLocalTarget(target) {
            (upstreamResponse, usedTarget, relayTerminal) = await Self.executeLocal(
                head: head,
                bodyData: forwardBodyData,
                primaryTarget: target,
                model: model,
                router: router,
                httpClient: httpClient,
                routeState: &routeState,
                requestID: requestID,
                health: localHealth,
                relayContext: relayContext
            )
            streamsViaLocalRelay = upstreamResponse != nil
        } else {
            (upstreamResponse, usedTarget) = await Self.executeWithFailover(
                head: head,
                bodyData: forwardBodyData,
                primaryTarget: target,
                model: model,
                router: router,
                httpClient: httpClient,
                routeState: &routeState,
                requestID: requestID
            )
            streamsViaLocalRelay = false
        }

        // 5. Write back mutated route state.
        await router.updateRouteState(model: model, state: routeState)

        guard let upstreamResponse, let usedTarget else {
            if let branchLease {
                await requestCoordinator.complete(lease: branchLease, replay: nil)
            }
            let duration = Date.now.timeIntervalSince(startTime)
            let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                ? .passthrough
                : .mapped(targetModel: target.targetModel ?? model)
            let entry = TrafficEntry(
                model: model,
                routeType: entryRouteType,
                requestKind: requestKind,
                httpStatus: relayTerminal?.status ?? 502,
                duration: duration
            )
            await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
            if let relayTerminal {
                await Self.sendAnthropicError(
                    channel: channel,
                    status: HTTPResponseStatus(statusCode: relayTerminal.status),
                    type: relayTerminal.anthropicType,
                    message: relayTerminal.message)
            } else {
                await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable")
            }
            return
        }

        // 6. Build usage callback for the vendor that actually served the request.
        let statsModel = usedTarget.targetModel ?? model
        let entryRouteType: TrafficEntry.RouteType = usedTarget.isPassthrough
            ? .passthrough
            : .mapped(targetModel: usedTarget.targetModel ?? model)

        // Capture output tokens + first-body-byte time for TTFT/TPS display
        // in the traffic log. Safe: both fire during `await relay()` below,
        // reads happen after relay returns.
        nonisolated(unsafe) var capturedOutputTokens: Int?
        nonisolated(unsafe) var capturedFirstByteAt: Date?

        let sourceModelForStats: String? = usedTarget.isPassthrough ? nil : model
        let toolCallGuard = Self.toolCallGuard(for: usedTarget, catalog: toolCatalog)

        let vendorID = usedTarget.vendorID
        let onUsage: ResponseRelay.UsageCallback = { [tokenStatsStore] input, output, cacheRead in
            capturedOutputTokens = output
            if let vendorID {
                Task { @MainActor in
                    tokenStatsStore.add(vendorID: vendorID, model: statsModel, input: input, output: output, cacheRead: cacheRead, sourceModel: sourceModelForStats)
                }
            }
        }

        // 7. Log status with readable text.
        let statusCode = Int(upstreamResponse.status.code)
        let elapsedMS = Int(Date.now.timeIntervalSince(startTime) * 1000)
        AppLog.proxy.debug(
            "[Proxy] [\(requestID)] Response: \(statusCode) \(HTTPStatusText.text(for: statusCode)) model=\(model) vendor=\(usedTarget.vendorName) \(elapsedMS)ms"
        )

        // 8. Relay response. The stream runs in a child task that is cancelled
        // when the client channel goes away, so a mid-stream client disconnect
        // aborts the upstream body (AsyncHTTPClient cancels the request and
        // tears the connection down). Local (splash) targets stream through
        // LocalTarget's cut-protected passthrough instead — no branch capture
        // (local model, no replayable vendor thinking); usage still flows:
        // `onUsage` is keyed to the target that actually served, so a relay
        // answer reached via the splash rule's backup ladder meters correctly.
        let relayStreamTask = Task { () -> ReplayableBranchResponse? in
            let onFirstBodyByte: @Sendable () -> Void = {
                if capturedFirstByteAt == nil { capturedFirstByteAt = Date.now }
            }
            if streamsViaLocalRelay {
                await LocalTarget.relayStream(
                    upstreamResponse: upstreamResponse, to: channel, requestID: requestID,
                    onUsage: onUsage, onFirstBodyByte: onFirstBodyByte)
                return nil
            }
            return await ResponseRelay.relay(
                upstreamResponse: upstreamResponse,
                to: channel,
                onUsage: onUsage,
                onFirstBodyByte: onFirstBodyByte,
                requestID: requestID,
                branchContext: preparedRequest.context,
                branchLease: branchLease,
                portableNormalizer: portableNormalizer,
                toolCallGuard: toolCallGuard,
                lineageBroker: lineageBroker,
                requestCoordinator: requestCoordinator
            )
        }
        channel.closeFuture.whenComplete { _ in relayStreamTask.cancel() }
        let replayableResponse = await relayStreamTask.value
        if let branchLease {
            await requestCoordinator.complete(lease: branchLease, replay: replayableResponse)
        }

        // 9. Publish traffic event with actual upstream status code.
        let duration = Date.now.timeIntervalSince(startTime)
        let entry = TrafficEntry(
            model: model,
            routeType: entryRouteType,
            requestKind: requestKind,
            httpStatus: statusCode,
            duration: duration,
            ttft: capturedFirstByteAt.map { $0.timeIntervalSince(startTime) },
            outputTokens: capturedOutputTokens
        )
        await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
    }

    /// Claude Code sends a fire-and-forget `HEAD /api/hello` to warm the connection at startup.
    /// No Messages API endpoint accepts HEAD, so every HEAD request is answered locally.
    static func isLocalProbe(_ head: HTTPRequestHead) -> Bool {
        head.method == .HEAD
    }

    private static func requestKind(for uri: String) -> TrafficEntry.RequestKind {
        let path = URLComponents(string: "http://localhost\(uri)")?.path ?? uri
        switch path {
        case "/v1/messages":
            return .generation
        case "/v1/messages/count_tokens":
            return .countTokens
        default:
            return .auxiliary(endpointPath: path)
        }
    }

    /// Vendors without Anthropic `count_tokens` support get a local 404 instead of a forwarded request.
    static func answersCountTokensLocally(
        requestKind: TrafficEntry.RequestKind,
        target: RoutingSnapshot.RouteTarget
    ) -> Bool {
        requestKind == .countTokens && !target.isPassthrough && !target.supportsAnthropicCountTokens
    }

    /// Anthropic-shaped error body for a locally answered `count_tokens` request.
    static func countTokensUnsupportedBody(vendorName: String) -> Data {
        let body: [String: Any] = [
            "type": "error",
            "error": [
                "type": "not_found_error",
                "message": "Token counting is not supported by \(vendorName). ModelProxy answered locally; Claude Code falls back to a local estimate."
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    static func toolCallGuard(
        for target: RoutingSnapshot.RouteTarget,
        catalog: ToolCallInputGuard.ToolCatalog
    ) -> ToolCallInputGuard? {
        target.repairsAnthropicToolCalls ? ToolCallInputGuard(catalog: catalog) : nil
    }

    private static func collectResponseBody(_ response: HTTPClientResponse) async throws -> Data {
        var data = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        return data
    }

    private struct RequestScopeKeys {
        let sessionScopeKey: String?
        let coordinationScopeKey: String?
    }

    static let claudeCodeSessionHeader = "x-claude-code-session-id"
    static let claudeCodeAgentHeader = "x-claude-code-agent-id"
    static let claudeCodeRequestClassHeader = "x-claude-code-request-class"

    private static func requestScopeKeys(
        bodyData: Data,
        headers: HTTPHeaders,
        clientName: String,
        channel: any Channel
    ) -> RequestScopeKeys {
        if let explicit = explicitSessionScopeKey(from: bodyData) {
            let explicitScopeKey = "\(clientName)|explicit|\(explicit)"
            return RequestScopeKeys(
                sessionScopeKey: explicitScopeKey,
                coordinationScopeKey: explicitScopeKey
            )
        }
        // Claude Code identifies its session (and each subagent) in headers. Use them only to
        // coordinate in-flight requests: persistent branch reuse stays content-addressed, so a
        // `/branch` fork or a resumed session still finds the vendor transcript it continues.
        if let coordinationScopeKey = claudeCodeCoordinationScopeKey(
            headers: headers,
            bodyData: bodyData,
            clientName: clientName
        ) {
            return RequestScopeKeys(sessionScopeKey: nil, coordinationScopeKey: coordinationScopeKey)
        }
        let channelIdentity = ObjectIdentifier(channel as AnyObject)
        return RequestScopeKeys(
            sessionScopeKey: nil,
            coordinationScopeKey: "\(clientName)|channel|\(channelIdentity)"
        )
    }

    /// The branch coordinator matches in-flight requests by vendor and message hashes only, so the
    /// scope also carries a fingerprint of everything else in the body (model, system, tools, params).
    /// A retry of the same request still joins the one in flight; a concurrent request in the same
    /// session that shares `messages` but differs elsewhere never receives the other's response.
    static func claudeCodeCoordinationScopeKey(headers: HTTPHeaders, bodyData: Data, clientName: String) -> String? {
        guard let sessionID = headers.first(name: claudeCodeSessionHeader), !sessionID.isEmpty else {
            return nil
        }
        var key = "\(clientName)|cc-session|\(sessionID)"
        if let agentID = headers.first(name: claudeCodeAgentHeader), !agentID.isEmpty {
            key += "|agent|\(agentID)"
        }
        key += "|shape|\(requestShapeFingerprint(bodyData))"
        return key
    }

    static func requestShapeFingerprint(_ bodyData: Data) -> String {
        guard var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return String(ConversationFingerprint().sha256Hex(bodyData).prefix(16))
        }
        json.removeValue(forKey: "messages")
        let shapeData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? bodyData
        return String(ConversationFingerprint().sha256Hex(shapeData).prefix(16))
    }

    /// Whether the request body opted into streaming — the off-peak
    /// ticket-plane admission gate (a non-streaming request must never
    /// queue). Same tolerance as OffPeakTarget's pre-flight: JSON-parse,
    /// top-level `stream == true`; malformed JSON, a non-object body, or an
    /// absent/non-Bool field is NOT a stream request.
    static func requestIsStream(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["stream"] as? Bool == true
    }

    /// Reads `x-claude-code-request-class` (sent with `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`);
    /// without it, a subagent is still recognizable by its agent id header.
    static func claudeCodeRequestClass(from headers: HTTPHeaders) -> TrafficEntry.RequestClass? {
        if let value = headers.first(name: claudeCodeRequestClassHeader),
           let requestClass = TrafficEntry.RequestClass(rawValue: value.lowercased()) {
            return requestClass
        }
        if let agentID = headers.first(name: claudeCodeAgentHeader), !agentID.isEmpty {
            return .subagent
        }
        return nil
    }

    private static func explicitSessionScopeKey(from bodyData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        let directKeys = ["session_id", "conversation_id", "thread_id"]
        for key in directKeys {
            if let value = json[key] as? String, !value.isEmpty {
                return "\(key)=\(value)"
            }
        }

        if let metadata = json["metadata"] as? [String: Any] {
            for key in directKeys {
                if let value = metadata[key] as? String, !value.isEmpty {
                    return "metadata.\(key)=\(value)"
                }
            }
        }

        if let container = json["container"] as? [String: Any],
           let value = container["id"] as? String,
           !value.isEmpty {
            return "container.id=\(value)"
        }

        return nil
    }

    // MARK: - Failover logic

    /// Execute upstream request with optional 429 failover to backup target.
    /// Returns the response and the target that was actually used, or (nil, nil) on total failure.
    private static func executeWithFailover(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?) {

        // Try with primary (or current active) target.
        let primaryResponse = await Self.executeUpstream(
            head: head,
            bodyData: bodyData,
            target: primaryTarget,
            httpClient: httpClient,
            requestID: requestID
        )

        guard let primaryResponse else {
            // Network-level failure (unreachable).
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
            return (nil, nil)
        }

        let statusCode = Int(primaryResponse.status.code)

        // Success: reset failCount.
        if statusCode < 400 {
            routeState.failCount = 0
            return (primaryResponse, primaryTarget)
        }

        // 429 on mapped route: try failover to backup.
        if statusCode == 429 && !primaryTarget.isPassthrough {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }

            // Get backup targets from router.
            if let allTargets = await router.targets(for: model), allTargets.count > 1 {
                let backupTarget = (primaryTarget.vendorID == allTargets[0].vendorID) ? allTargets[1] : allTargets[0]
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] Rate limited on \(primaryTarget.vendorName), failing over to \(backupTarget.vendorName)"
                )

                let backupResponse = await Self.executeUpstream(
                    head: head,
                    bodyData: bodyData,
                    target: backupTarget,
                    httpClient: httpClient,
                    requestID: requestID
                )
                if let backupResponse {
                    if Int(backupResponse.status.code) < 400 {
                        routeState.failCount = 0
                    }
                    return (backupResponse, backupTarget)
                }
            }

            // No backup or backup also failed: return original 429.
            return (primaryResponse, primaryTarget)
        }

        // Non-429 error: forward as-is, increment failCount.
        if statusCode >= 400 {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
        }

        return (primaryResponse, primaryTarget)
    }

    // MARK: - Relay execution (signed ladder)

    /// Relay-kind execution: the signed ladder (RelayTarget) plus Task 7's
    /// degraded machine. Returns the streamable response + serving target,
    /// or a terminal the caller writes to the client when no response
    /// survived the policy.
    private static func executeRelay(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String,
        relayContext: RelayTarget.Context?
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?, RelayTarget.UpstreamTerminal?) {
        guard let relayContext else {
            return (nil, nil, RelayTarget.UpstreamTerminal(
                status: 502,
                anthropicType: "api_error",
                message: "Relay vendor '\(primaryTarget.vendorName)' requires signing but no signing context is configured."))
        }
        let relayHealth = relayContext.relayHealth

        // Task 7 admission: while the relay plane is degraded, the signed
        // ladder runs only on the probe cadence; a risk cooldown blocks
        // relay attempts outright. Without a health actor (legacy contexts,
        // tests) everything attempts, exactly like before.
        if let relayHealth {
            let admission = await relayHealth.admission()
            switch admission {
            case .attempt, .probe:
                break
            case .serveViaFallback, .riskBlocked:
                if let served = await Self.serveRuleBackup(
                    head: head, bodyData: bodyData, primaryTarget: primaryTarget, model: model,
                    router: router, httpClient: httpClient, routeState: &routeState, requestID: requestID,
                    relayContext: relayContext, relayHealth: relayHealth,
                    allowRelayBackup: false, allowDirectFallback: true, reason: "Relay degraded")
                {
                    return served
                }
                if admission == .riskBlocked {
                    return (nil, nil, RelayTarget.UpstreamTerminal(
                        status: 502, anthropicType: "api_error",
                        message: "Relay risk-control cooldown active — attempts blocked without retry."))
                }
                // Degraded with no usable fallback configured: today's
                // behavior — the signed ladder runs and its own terminal
                // answers on failure.
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] Relay degraded with no fallback target — attempting signed ladder")
            }
        }

        let outcome = await RelayTarget.execute(
            head: head,
            bodyData: bodyData,
            target: primaryTarget,
            httpClient: httpClient,
            context: relayContext,
            requestID: requestID)

        switch outcome {
        case .rateLimitedAfterRetry, .concurrencyLimitedAfterRetries:
            // The retries already ran inside the ladder — fall back to the
            // rule's next target if one exists, else answer 529. The chain
            // demonstrably works (a business answer arrived): a probe in
            // flight has recovered.
            await relayHealth?.noteRelayServed()
            if let served = await Self.serveRuleBackup(
                head: head, bodyData: bodyData, primaryTarget: primaryTarget, model: model,
                router: router, httpClient: httpClient, routeState: &routeState, requestID: requestID,
                relayContext: relayContext, relayHealth: relayHealth,
                allowRelayBackup: true, allowDirectFallback: false, reason: "Rate limited")
            {
                return served
            }
            return (nil, nil, Self.terminal(for: outcome))
        case .signingUnavailable, .transportFailed:
            // Signing-class failure: enter/advance the degraded machine, then
            // serve THIS request via the fallback edge instead of a 502.
            await relayHealth?.noteSigningFailure()
            if let served = await Self.serveRuleBackup(
                head: head, bodyData: bodyData, primaryTarget: primaryTarget, model: model,
                router: router, httpClient: httpClient, routeState: &routeState, requestID: requestID,
                relayContext: relayContext, relayHealth: relayHealth,
                allowRelayBackup: false, allowDirectFallback: true, reason: "Signing unavailable")
            {
                return served
            }
            return (nil, nil, Self.terminal(for: outcome))
        case .credentialsExpired:
            // Recovery is an interactive re-login, not a timed probe: relay
            // health stays untouched (the re-login event already fired) and
            // the request serves via the fallback edge.
            if let served = await Self.serveRuleBackup(
                head: head, bodyData: bodyData, primaryTarget: primaryTarget, model: model,
                router: router, httpClient: httpClient, routeState: &routeState, requestID: requestID,
                relayContext: relayContext, relayHealth: relayHealth,
                allowRelayBackup: false, allowDirectFallback: true, reason: "Credentials expired")
            {
                return served
            }
            return (nil, nil, Self.terminal(for: outcome))
        case .riskControl:
            // The risk event fired inside the ladder; the cooldown starts and
            // this request serves via the fallback edge.
            await relayHealth?.noteRiskControl()
            if let served = await Self.serveRuleBackup(
                head: head, bodyData: bodyData, primaryTarget: primaryTarget, model: model,
                router: router, httpClient: httpClient, routeState: &routeState, requestID: requestID,
                relayContext: relayContext, relayHealth: relayHealth,
                allowRelayBackup: false, allowDirectFallback: true, reason: "Risk control")
            {
                return served
            }
            return (nil, nil, Self.terminal(for: outcome))
        case .quotaExhausted:
            // The fallback edge bills the SAME weekly quota — serving it
            // would 1113 too. The 429-shaped terminal answers (the chain
            // worked: the quota poll has already ticked).
            await relayHealth?.noteRelayServed()
            return (nil, nil, Self.terminal(for: outcome))
        case .responded(let response):
            if Int(response.status.code) < 400 { routeState.failCount = 0 }
            await relayHealth?.noteRelayServed()
            return (response, primaryTarget, nil)
        }
    }

    /// The rule's backup serve, shared by the rate-limit fallback and Task
    /// 7's degraded fallback. nil ONLY when nothing served — the caller
    /// then answers its own terminal. A relay-kind backup runs its own
    /// signed ladder (skipped under signing degradation — a dead chain
    /// cannot serve a signed backup); any other backup serves through
    /// `executeUpstream` with the fallback edge's key lifecycle applied.
    /// When the matched rule has NO usable backup (class rules carry none —
    /// controller ruling, fix round 1) and the caller is on a degraded
    /// admission path, the fallback edge serves DIRECTLY (no rule backup,
    /// no config mutation); the rate-limit path keeps today's semantics
    /// (no backup → its own terminal).
    private static func serveRuleBackup(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String,
        relayContext: RelayTarget.Context,
        relayHealth: RelayHealth?,
        allowRelayBackup: Bool,
        allowDirectFallback: Bool,
        reason: String
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?, RelayTarget.UpstreamTerminal?)? {
        let allTargets = await router.targets(for: model)
        guard let allTargets, allTargets.count > 1 else {
            return await serveDirectFallback(
                head: head, bodyData: bodyData, primaryTarget: primaryTarget,
                httpClient: httpClient, routeState: &routeState, requestID: requestID,
                relayHealth: relayHealth, allowDirectFallback: allowDirectFallback, reason: reason)
        }
        let backupTarget = (primaryTarget.vendorID == allTargets[0].vendorID) ? allTargets[1] : allTargets[0]
        AppLog.proxy.info(
            "[Proxy] [\(requestID)] \(reason) on relay \(primaryTarget.vendorName), failing over to \(backupTarget.vendorName)"
        )
        if backupTarget.vendorKind == .relay {
            guard allowRelayBackup else {
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] Relay-kind backup \(backupTarget.vendorName) skipped: the signing chain is the failure")
                return await serveDirectFallback(
                    head: head, bodyData: bodyData, primaryTarget: primaryTarget,
                    httpClient: httpClient, routeState: &routeState, requestID: requestID,
                    relayHealth: relayHealth, allowDirectFallback: allowDirectFallback, reason: reason)
            }
            // A relay backup runs its own signed ladder (no further fallback).
            switch await RelayTarget.execute(
                head: head, bodyData: bodyData, target: backupTarget,
                httpClient: httpClient, context: relayContext, requestID: requestID)
            {
            case .responded(let response):
                if Int(response.status.code) < 400 { routeState.failCount = 0 }
                await relayHealth?.noteRelayServed()
                return (response, backupTarget, nil)
            case let terminalOutcome:
                return (nil, nil, Self.terminal(for: terminalOutcome))
            }
        }
        if let backupResponse = await Self.executeBackupUpstream(
            head: head, bodyData: bodyData, target: backupTarget,
            httpClient: httpClient, requestID: requestID, relayHealth: relayHealth)
        {
            if Int(backupResponse.status.code) < 400 { routeState.failCount = 0 }
            return (backupResponse, backupTarget, nil)
        }
        return (nil, nil, RelayTarget.UpstreamTerminal(
            status: 502, anthropicType: "api_error", message: "Upstream unreachable"))
    }

    /// The DIRECT fallback-edge serve for degraded admissions with no
    /// usable rule backup (fix round 1): the edge target comes from
    /// RelayHealth (pushed from the live config), carries the matched
    /// rule's tier target model, and runs the same key lifecycle as the
    /// rule-backup serve. Not allowed (rate-limit path) or nothing
    /// configured/usable → nil → the caller's own terminal, today's shape.
    private static func serveDirectFallback(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String,
        relayHealth: RelayHealth?,
        allowDirectFallback: Bool,
        reason: String
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?, RelayTarget.UpstreamTerminal?)? {
        guard allowDirectFallback, let relayHealth,
            let edgeTarget = await relayHealth.fallbackEdgeTarget()
        else { return nil }
        AppLog.proxy.info(
            "[Proxy] [\(requestID)] \(reason): no usable rule backup — serving the fallback edge \(edgeTarget.vendorName) directly"
        )
        let serveTarget = edgeTarget.withTargetModel(primaryTarget.targetModel)
        if let response = await Self.executeBackupUpstream(
            head: head, bodyData: bodyData, target: serveTarget,
            httpClient: httpClient, requestID: requestID, relayHealth: relayHealth)
        {
            if Int(response.status.code) < 400 { routeState.failCount = 0 }
            return (response, serveTarget, nil)
        }
        return nil
    }

    /// The off-peak gate-failure serve (Task 4): the rule's backup target
    /// serves the request — a relay-kind backup through its own signed
    /// ladder, any other through the plain upstream send. No usable backup
    /// (single-target rule, or the backup is itself an off-peak target —
    /// the same closed window gates both) returns the exact 503 terminal;
    /// the caller's terminal path writes it to the client and logs the
    /// traffic row.
    private static func serveOffPeakFallback(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String,
        relayContext: RelayTarget.Context?,
        failedGate: String
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?, RelayTarget.UpstreamTerminal?) {
        let allTargets = await router.targets(for: model)
        let backupTarget = allTargets.flatMap { targets in
            targets.count > 1
                ? (primaryTarget.vendorID == targets[0].vendorID ? targets[1] : targets[0])
                : nil
        }
        guard let backupTarget, backupTarget.vendorKind != .offPeak else {
            AppLog.proxy.info(
                "[Proxy] [\(requestID)] Off-peak gate failed (\(failedGate)) on \(primaryTarget.vendorName) with no usable backup target — answering 503"
            )
            return (nil, nil, RelayTarget.UpstreamTerminal(
                status: 503,
                anthropicType: "off_peak_unavailable",
                message: "The off-peak window is closed and this rule has no backup target."))
        }
        AppLog.proxy.info(
            "[Proxy] [\(requestID)] Off-peak gate failed (\(failedGate)) on \(primaryTarget.vendorName), serving backup \(backupTarget.vendorName)"
        )
        if backupTarget.vendorKind == .relay {
            guard let relayContext else {
                return (nil, nil, RelayTarget.UpstreamTerminal(
                    status: 502,
                    anthropicType: "api_error",
                    message: "Relay vendor '\(backupTarget.vendorName)' requires signing but no signing context is configured."))
            }
            switch await RelayTarget.execute(
                head: head, bodyData: bodyData, target: backupTarget,
                httpClient: httpClient, context: relayContext, requestID: requestID)
            {
            case .responded(let response):
                if Int(response.status.code) < 400 { routeState.failCount = 0 }
                return (response, backupTarget, nil)
            case let terminalOutcome:
                return (nil, nil, Self.terminal(for: terminalOutcome))
            }
        }
        if let response = await Self.executeUpstream(
            head: head, bodyData: bodyData, target: backupTarget,
            httpClient: httpClient, requestID: requestID)
        {
            if Int(response.status.code) < 400 { routeState.failCount = 0 }
            return (response, backupTarget, nil)
        }
        return (nil, nil, RelayTarget.UpstreamTerminal(
            status: 502, anthropicType: "api_error", message: "Upstream unreachable"))
    }

    /// One upstream serve on a rule backup. When the target is the fallback
    /// edge, its key lifecycle applies: the credential resolves lazily
    /// (stored config key first, mint on empty), a 401 re-mints ONCE and
    /// retries once, and a no-balance 1113 cools the key for 1 h (the
    /// response surfaces — never retried). Fallback outcomes NEVER touch
    /// the relay machine (the never-launder rule); non-fallback-edge
    /// backups serve exactly like before.
    private static func executeBackupUpstream(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        requestID: String,
        relayHealth: RelayHealth?
    ) async -> HTTPClientResponse? {
        guard let relayHealth, await relayHealth.isFallbackEdge(target.baseURL) else {
            return await Self.executeUpstream(
                head: head, bodyData: bodyData, target: target,
                httpClient: httpClient, requestID: requestID)
        }
        // Resolve the credential: a stored (config-seeded) key wins; an
        // empty one mints lazily. nil (cooling / mint failed / no minter)
        // means the edge cannot serve this request.
        var key = target.apiKey
        if key.isEmpty {
            guard let minted = await relayHealth.fallbackKey() else { return nil }
            key = minted
        }
        guard var response = await Self.executeUpstream(
            head: head, bodyData: bodyData, target: target.withAPIKey(key),
            httpClient: httpClient, requestID: requestID, apiKeyOnlyAuth: true)
        else { return nil }

        // A 401 means the credential is stale server-side: re-mint once and
        // retry once; anything after that (or an unchanged key) surfaces.
        if Int(response.status.code) == 401 {
            let (_, rewrapped401) = await RelayTarget.drainErrorBody(response)
            if let fresh = await relayHealth.fallbackKey(forceRemint: true), fresh != key,
                let retry = await Self.executeUpstream(
                    head: head, bodyData: bodyData, target: target.withAPIKey(fresh),
                    httpClient: httpClient, requestID: requestID, apiKeyOnlyAuth: true)
            {
                response = retry
            } else {
                response = rewrapped401
            }
        }

        // A no-balance fallback (business code 1113, parsed JSON only) cools
        // the KEY for 1 h; the response surfaces and the relay machine is
        // untouched.
        if Int(response.status.code) >= 400 {
            let (error, rewrapped) = await RelayTarget.drainErrorBody(response)
            if error.code == 1113 {
                await relayHealth.noteFallbackKeyNoBalance()
            }
            return rewrapped
        }
        return response
    }

    /// Maps a relay outcome that produced no streamable response to the
    /// proxy-authored terminal the client receives instead.
    private static func terminal(for outcome: RelayTarget.Outcome) -> RelayTarget.UpstreamTerminal {
        switch outcome {
        case .signingUnavailable(let reason):
            return RelayTarget.UpstreamTerminal(
                status: 502, anthropicType: "api_error",
                message: "Relay signing unavailable: \(reason)")
        case .credentialsExpired(let reason):
            return RelayTarget.UpstreamTerminal(
                status: 502, anthropicType: "authentication_error",
                message: "zcode credentials expired — re-login required. (\(reason))")
        case .transportFailed(let reason):
            return RelayTarget.UpstreamTerminal(
                status: 502, anthropicType: "api_error",
                message: "Relay upstream unreachable: \(reason)")
        case .rateLimitedAfterRetry:
            return RelayTarget.UpstreamTerminal(
                status: 529, anthropicType: "overloaded_error",
                message: "Relay rate limited (429 after retry) and no fallback rule is configured.")
        case .quotaExhausted(let reason):
            // 429-shaped by design (relay fidelity Task 6): the plan quota is
            // gone — the client's own rate-limit handling applies, and the
            // quota poll has already been ticked for the UI.
            return RelayTarget.UpstreamTerminal(
                status: 429, anthropicType: "rate_limit_error",
                message: "Relay plan quota exhausted, no retry is possible. (\(reason))")
        case .riskControl(let reason):
            return RelayTarget.UpstreamTerminal(
                status: 502, anthropicType: "api_error",
                message: "Relay risk control engaged — request blocked upstream, no retry. (\(reason))")
        case .concurrencyLimitedAfterRetries:
            return RelayTarget.UpstreamTerminal(
                status: 529, anthropicType: "overloaded_error",
                message: "Relay concurrency-limited (codes 3008/3009/3010) after retries and no fallback rule is configured.")
        case .responded:
            preconditionFailure("responded outcomes stream; they do not map to a terminal")
        }
    }

    // MARK: - Local execution (splash ladder)

    /// Local-target execution: `LocalTarget.executeWithFallback` over the
    /// rule's target array (`router.targets(for:)` — the same class-rule
    /// failover arrays and eligibility the resolver applied). Route-state
    /// rule (deliberately narrower than the mapped path's): a 2xx resets
    /// `failCount`; client errors (4xx) neither reset nor increment — they
    /// are request problems, not availability signals; ladder failures
    /// (primary 5xx with no backup served, fully unreachable chain)
    /// increment, flipping the active target after 10 consecutive ones.
    private static func executeLocal(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String,
        health: LocalHealthMonitor?,
        relayContext: RelayTarget.Context?
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?, RelayTarget.UpstreamTerminal?) {
        let targets = await router.targets(for: model) ?? [primaryTarget]
        switch await LocalTarget.executeWithFallback(
            head: head,
            bodyData: bodyData,
            targets: targets,
            httpClient: httpClient,
            requestID: requestID,
            health: health,
            relayContext: relayContext)
        {
        case .served(let response, let target):
            if Int(response.status.code) < 400 { routeState.failCount = 0 }
            return (response, target, nil)
        case .primaryError(let response, let target):
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
            return (response, target, nil)
        case .unreachable(let reason):
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
            return (nil, nil, RelayTarget.UpstreamTerminal(
                status: 502, anthropicType: "api_error",
                message: "Local target unreachable: \(reason)"))
        }
    }

    /// Build and execute a single upstream request for a given target.
    /// `apiKeyOnlyAuth` overrides the fallback-edge header derivation (the
    /// degraded serve path KNOWS it is serving the edge even when the
    /// configured edge URL is not the pinned constant).
    private static func executeUpstream(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        requestID: String,
        apiKeyOnlyAuth: Bool? = nil
    ) async -> HTTPClientResponse? {
        let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        guard URL(string: finalURLString) != nil else { return nil }

        let upstreamHeaders = Self.upstreamHeaders(
            from: head.headers, target: target, apiKeyOnlyAuth: apiKeyOnlyAuth)

        var bodyData = bodyData
        if !target.isPassthrough, target.stripsClaudeOnlyRequestFields {
            let stripped = Self.stripClaudeOnlyRequestFields(in: bodyData)
            bodyData = stripped.bodyData
            if !stripped.removedFields.isEmpty {
                AppLog.proxy.debug(
                    "[Proxy] [\(requestID)] Stripped Claude-only fields for vendor=\(target.vendorName): \(stripped.removedFields.joined(separator: ", "))"
                )
            }
        }

        // Replace model field using prepared body. Vendors flagged
        // applyGLMCanonicalization (the fallback edge) run the value through
        // RelayTarget.canonicalModel first — a documented
        // routing-compatibility transform so retired GLM names never leak
        // raw on that path.
        if target.applyGLMCanonicalization {
            if let source = target.targetModel ?? RelayTarget.bodyModelField(bodyData) {
                let canonical = RelayTarget.canonicalModel(source)
                let replacement = Self.replaceModelField(in: bodyData, with: canonical)
                bodyData = replacement.data
                if replacement.replaced, canonical != source {
                    AppLog.proxy.debug(
                        "[Proxy] [\(requestID)] Model canonicalized for vendor=\(target.vendorName): \(source) → \(canonical)"
                    )
                }
            }
        } else if let targetModel = target.targetModel {
            let replacement = Self.replaceModelField(in: bodyData, with: targetModel)
            bodyData = replacement.data
            let delta = replacement.newLength - replacement.originalLength
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] Model replace target=\(targetModel) replaced=\(replacement.replaced) body=\(replacement.originalLength)→\(replacement.newLength)B delta=\(delta)B"
            )
            if !replacement.replaced {
                AppLog.proxy.warning("[Proxy] [\(requestID)] Model field not found at top-level; request body forwarded unchanged")
            }
        }

        var upstreamRequest = HTTPClientRequest(url: finalURLString)
        upstreamRequest.method = head.method
        upstreamRequest.headers = upstreamHeaders
        upstreamRequest.body = .bytes(bodyData)

        do {
            // Note: readTimeoutSeconds bounds the time until the response head arrives. AsyncHTTPClient
            // cancels this deadline once `execute` returns, so streamed bodies are not cut off; a
            // non-streaming response must finish within it. AsyncHTTPClient doesn't support a
            // per-request connect timeout; connectTimeoutSeconds is set on the pool in ProxyServer.start().
            return try await httpClient.execute(upstreamRequest, timeout: .seconds(Int64(target.readTimeoutSeconds)))
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Upstream error for \(target.vendorName): \(error)")
            return nil
        }
    }

    /// Headers sent upstream: hop-by-hop headers dropped, and for mapped vendors the vendor's key
    /// replaces the client's credentials. `apiKeyOnlyAuth` (nil = derive from
    /// the pinned fallback-edge URL) selects the CLI zai-api template where
    /// the credential rides `x-api-key` and replaces the authorization header.
    static func upstreamHeaders(
        from requestHeaders: HTTPHeaders,
        target: RoutingSnapshot.RouteTarget,
        apiKeyOnlyAuth: Bool? = nil
    ) -> HTTPHeaders {
        var upstreamHeaders = HTTPHeaders()
        for (name, value) in requestHeaders {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" || lower == "transfer-encoding" || lower == "content-length" || lower == "accept-encoding" { continue }
            // Claude Code session/agent identifiers are meant for the local gateway, not third-party vendors.
            if !target.isPassthrough, lower.hasPrefix("x-claude-code-") { continue }
            if !target.isPassthrough, target.stripsClaudeOnlyRequestFields, lower == "anthropic-beta" { continue }
            upstreamHeaders.add(name: name, value: value)
        }
        upstreamHeaders.add(name: "Accept-Encoding", value: "gzip, deflate")
        if !target.isPassthrough {
            upstreamHeaders.remove(name: "authorization")
            upstreamHeaders.remove(name: "x-api-key")
            let edgeAuth = apiKeyOnlyAuth ?? ApiKeyMinter.isFallbackEdge(target.baseURL)
            if edgeAuth {
                // CLI zai-api provider template (relay fidelity Task 7): the
                // credential rides `x-api-key` and REPLACES the authorization
                // header entirely.
                upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
            } else {
                upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
                upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
            }
        }
        if let host = URL(string: target.baseURL)?.host {
            upstreamHeaders.remove(name: "host")
            upstreamHeaders.add(name: "Host", value: host)
        }
        return upstreamHeaders
    }

    // MARK: - Helpers

    struct ModelReplacementResult {
        let data: Data
        let replaced: Bool
        let originalLength: Int
        let newLength: Int
    }

    /// Replace only the top-level `"model"` field value while preserving all other bytes exactly.
    /// This avoids mutating unrelated payload bytes, including thinking/signature blocks.
    static func replaceModelField(in data: Data, with newModel: String) -> ModelReplacementResult {
        let originalLength = data.count
        let bytes = [UInt8](data)
        guard let modelValueRange = Self.topLevelModelValueRange(in: bytes) else {
            return ModelReplacementResult(
                data: data,
                replaced: false,
                originalLength: originalLength,
                newLength: originalLength
            )
        }

        let escapedModelBytes = Self.escapeJSONString(newModel)
        var result = Data()
        result.reserveCapacity(originalLength - modelValueRange.count + escapedModelBytes.count)
        result.append(contentsOf: bytes[0..<modelValueRange.lowerBound])
        result.append(contentsOf: escapedModelBytes)
        result.append(contentsOf: bytes[modelValueRange.upperBound..<bytes.count])

        return ModelReplacementResult(
            data: result,
            replaced: true,
            originalLength: originalLength,
            newLength: result.count
        )
    }

    /// Clamp the top-level `"max_tokens"` value into `[min, max]` while
    /// preserving all other bytes exactly (documented routing-compatibility
    /// transform — the relay rejects out-of-range values with 400 code 1210).
    /// Splices only when the current integer value is out of range; an absent,
    /// in-range, or non-integer value leaves the body byte-unchanged.
    static func clampMaxTokensField(_ body: Data, min: Int = 1, max: Int = 131_072) -> Data {
        let bytes = [UInt8](body)
        guard let valueRange = Self.topLevelNumberValueRange(in: bytes, key: "max_tokens"),
            let value = Int(String(decoding: bytes[valueRange], as: UTF8.self)),
            value < min || value > max
        else { return body }

        let clamped = value < min ? min : max
        let clampedBytes = Array(String(clamped).utf8)
        var result = Data()
        result.reserveCapacity(bytes.count - valueRange.count + clampedBytes.count)
        result.append(contentsOf: bytes[0..<valueRange.lowerBound])
        result.append(contentsOf: clampedBytes)
        result.append(contentsOf: bytes[valueRange.upperBound..<bytes.count])
        return result
    }

    private static func topLevelModelValueRange(in bytes: [UInt8]) -> Range<Int>? {
        let quote: UInt8 = 34
        let colon: UInt8 = 58
        let openObject: UInt8 = 123
        let closeObject: UInt8 = 125
        let openArray: UInt8 = 91
        let closeArray: UInt8 = 93
        let modelKey = Array("model".utf8)

        var index = 0
        var depth = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == quote {
                guard let (stringRange, nextIndex) = Self.parseJSONString(in: bytes, startingAt: index) else {
                    return nil
                }

                if depth == 1 {
                    var cursor = nextIndex
                    while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                        cursor += 1
                    }

                    if cursor < bytes.count, bytes[cursor] == colon, bytes[stringRange].elementsEqual(modelKey) {
                        cursor += 1
                        while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                            cursor += 1
                        }

                        guard cursor < bytes.count, bytes[cursor] == quote,
                              let (modelValueRange, _) = Self.parseJSONString(in: bytes, startingAt: cursor) else {
                            return nil
                        }
                        return modelValueRange
                    }
                }

                index = nextIndex
                continue
            }

            switch byte {
            case openObject, openArray:
                depth += 1
            case closeObject, closeArray:
                depth = max(0, depth - 1)
            default:
                break
            }

            index += 1
        }

        return nil
    }

    /// Byte range of the top-level `key`'s numeric value, or nil when the key
    /// is absent at the top level or its value does not start a JSON number
    /// token. Sibling of `topLevelModelValueRange` (same depth-1 key scan,
    /// number value instead of string value).
    private static func topLevelNumberValueRange(in bytes: [UInt8], key: String) -> Range<Int>? {
        let quote: UInt8 = 34
        let colon: UInt8 = 58
        let openObject: UInt8 = 123
        let closeObject: UInt8 = 125
        let openArray: UInt8 = 91
        let closeArray: UInt8 = 93
        let minus: UInt8 = 45
        let keyBytes = Array(key.utf8)

        var index = 0
        var depth = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == quote {
                guard let (stringRange, nextIndex) = Self.parseJSONString(in: bytes, startingAt: index) else {
                    return nil
                }

                if depth == 1 {
                    var cursor = nextIndex
                    while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                        cursor += 1
                    }

                    if cursor < bytes.count, bytes[cursor] == colon, bytes[stringRange].elementsEqual(keyBytes) {
                        cursor += 1
                        while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                            cursor += 1
                        }

                        // The value must start a JSON number (`-` or a digit);
                        // anything else (null, string, object…) is not ours to touch.
                        guard cursor < bytes.count,
                            bytes[cursor] == minus || (48...57).contains(bytes[cursor])
                        else { return nil }
                        let start = cursor
                        cursor += 1
                        while cursor < bytes.count, Self.isJSONNumberByte(bytes[cursor]) {
                            cursor += 1
                        }
                        return start..<cursor
                    }
                }

                index = nextIndex
                continue
            }

            switch byte {
            case openObject, openArray:
                depth += 1
            case closeObject, closeArray:
                depth = max(0, depth - 1)
            default:
                break
            }

            index += 1
        }

        return nil
    }

    /// Bytes that may appear inside a JSON number token: digits plus
    /// `-`, `+`, `.`, `e`, `E`.
    private static func isJSONNumberByte(_ byte: UInt8) -> Bool {
        byte == 45 || byte == 43 || byte == 46 || byte == 101 || byte == 69
            || (48...57).contains(byte)
    }

    private static func parseJSONString(in bytes: [UInt8], startingAt start: Int) -> (Range<Int>, Int)? {
        let quote: UInt8 = 34
        let backslash: UInt8 = 92
        guard start < bytes.count, bytes[start] == quote else { return nil }

        var index = start + 1
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }

            if byte == backslash {
                escaped = true
                index += 1
                continue
            }

            if byte == quote {
                return ((start + 1)..<index, index + 1)
            }

            index += 1
        }

        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func escapeJSONString(_ value: String) -> [UInt8] {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34:
                escaped += "\\\""
            case 92:
                escaped += "\\\\"
            case 8:
                escaped += "\\b"
            case 12:
                escaped += "\\f"
            case 10:
                escaped += "\\n"
            case 13:
                escaped += "\\r"
            case 9:
                escaped += "\\t"
            case 0..<32:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return Array(escaped.utf8)
    }

    struct AnthropicBodySanitizationResult: Sendable, Equatable {
        let bodyData: Data
        let normalizedToolUseCount: Int
        let normalizedToolResultCount: Int
    }

    static func sanitizeAnthropicBodyIfNeeded(_ body: Data) -> AnthropicBodySanitizationResult {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return AnthropicBodySanitizationResult(
                bodyData: body,
                normalizedToolUseCount: 0,
                normalizedToolResultCount: 0
            )
        }

        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        guard normalized.changed else {
            return AnthropicBodySanitizationResult(
                bodyData: body,
                normalizedToolUseCount: 0,
                normalizedToolResultCount: 0
            )
        }

        json["messages"] = normalized.messages
        let normalizedBody = (try? TranscriptProjector.encodeJSONObject(json)) ?? body
        return AnthropicBodySanitizationResult(
            bodyData: normalizedBody,
            normalizedToolUseCount: normalized.normalizedToolUseCount,
            normalizedToolResultCount: normalized.normalizedToolResultCount
        )
    }

    private static func containsJSONStringField(_ data: Data, field: String) -> Bool {
        data.range(of: Data(("\"\(field)\"").utf8)) != nil
    }

    struct RequestStructureSummary: Sendable, Equatable {
        let bodyBytes: Int
        let messageCount: Int
        let assistantMessageCount: Int
        let arrayContentMessageCount: Int
        let stringContentMessageCount: Int
        let textBlockCount: Int
        let thinkingBlockCount: Int
        let signedThinkingBlockCount: Int
        let redactedThinkingBlockCount: Int
        let toolUseBlockCount: Int
        let toolResultBlockCount: Int
        let otherBlockCount: Int
        let topLevelThinkingType: String?
        let topLevelThinkingBudget: Int?
    }

    /// Thinking blocks present in the prepared (projected) body beyond those the client sent.
    static func restoredThinkingBlockCount(originalBody: Data, preparedBody: Data) -> Int {
        guard let original = summarizeRequestBody(originalBody),
              let prepared = summarizeRequestBody(preparedBody) else {
            return 0
        }
        return max(0, prepared.thinkingBlockCount - original.thinkingBlockCount)
    }

    static func summarizeRequestBody(_ body: Data) -> RequestStructureSummary? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let messages = json["messages"] as? [[String: Any]] ?? []
        let thinkingConfig = json["thinking"] as? [String: Any]

        var assistantMessageCount = 0
        var arrayContentMessageCount = 0
        var stringContentMessageCount = 0
        var textBlockCount = 0
        var thinkingBlockCount = 0
        var signedThinkingBlockCount = 0
        var redactedThinkingBlockCount = 0
        var toolUseBlockCount = 0
        var toolResultBlockCount = 0
        var otherBlockCount = 0

        for message in messages {
            if (message["role"] as? String) == "assistant" {
                assistantMessageCount += 1
            }

            if let blocks = message["content"] as? [[String: Any]] {
                arrayContentMessageCount += 1
                for block in blocks {
                    let blockType = (block["type"] as? String)?.lowercased()
                    switch blockType {
                    case "text":
                        textBlockCount += 1
                    case "thinking":
                        thinkingBlockCount += 1
                        if block["signature"] is String {
                            signedThinkingBlockCount += 1
                        }
                    case "redacted_thinking":
                        redactedThinkingBlockCount += 1
                    case "tool_use":
                        toolUseBlockCount += 1
                    case "tool_result":
                        toolResultBlockCount += 1
                    default:
                        otherBlockCount += 1
                    }
                }
            } else if message["content"] is String {
                stringContentMessageCount += 1
            }
        }

        return RequestStructureSummary(
            bodyBytes: body.count,
            messageCount: messages.count,
            assistantMessageCount: assistantMessageCount,
            arrayContentMessageCount: arrayContentMessageCount,
            stringContentMessageCount: stringContentMessageCount,
            textBlockCount: textBlockCount,
            thinkingBlockCount: thinkingBlockCount,
            signedThinkingBlockCount: signedThinkingBlockCount,
            redactedThinkingBlockCount: redactedThinkingBlockCount,
            toolUseBlockCount: toolUseBlockCount,
            toolResultBlockCount: toolResultBlockCount,
            otherBlockCount: otherBlockCount,
            topLevelThinkingType: thinkingConfig?["type"] as? String,
            topLevelThinkingBudget: thinkingConfig?["budget_tokens"] as? Int
        )
    }

    private static func logProjectionDiagnostics(
        requestID: String,
        originalBody: Data,
        preparedRequest: PreparedRequest
    ) {
        guard let original = summarizeRequestBody(originalBody),
              let prepared = summarizeRequestBody(preparedRequest.bodyData) else {
            return
        }

        let bodyDelta = prepared.bodyBytes - original.bodyBytes
        let thinkingConfig = prepared.topLevelThinkingType ?? "none"
        let budget = prepared.topLevelThinkingBudget.map(String.init) ?? "none"
        AppLog.proxy.debug(
            "[Proxy] [\(requestID)] ProjectionDiag: body=\(original.bodyBytes)→\(prepared.bodyBytes)B delta=\(bodyDelta) msgs=\(original.messageCount)→\(prepared.messageCount) assistant=\(original.assistantMessageCount)→\(prepared.assistantMessageCount) content[array/string]=\(original.arrayContentMessageCount)/\(original.stringContentMessageCount)→\(prepared.arrayContentMessageCount)/\(prepared.stringContentMessageCount) blocks[text/thinking/signed/redacted/tool_use/tool_result/other]=\(original.textBlockCount)/\(original.thinkingBlockCount)/\(original.signedThinkingBlockCount)/\(original.redactedThinkingBlockCount)/\(original.toolUseBlockCount)/\(original.toolResultBlockCount)/\(original.otherBlockCount)→\(prepared.textBlockCount)/\(prepared.thinkingBlockCount)/\(prepared.signedThinkingBlockCount)/\(prepared.redactedThinkingBlockCount)/\(prepared.toolUseBlockCount)/\(prepared.toolResultBlockCount)/\(prepared.otherBlockCount) thinking.config=\(thinkingConfig) budget=\(budget)"
        )

        if let context = preparedRequest.context {
            let portableBytes = preparedRequest.projectedPortableMessagesData?.count ?? 0
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ProjectionDiag: branch lineage=\(context.lineageKey) branch=\(context.branchKey) reused=\(context.reusedBranchHistory) reusedPortable=\(context.reusedPortableMessageCount) portableHashes=\(context.preparedPortableMessageHashes.count) portableBytes=\(portableBytes)"
            )
        }
    }

    private static func logCoordinatorDiagnostics(
        requestID: String,
        decision: BranchRequestAcquireDecision,
        context: PreparedBranchContext
    ) {
        switch decision {
        case .acquired(let lease):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=acquired lineage=\(context.lineageKey) branch=\(context.branchKey) generation=\(lease.generation) hashes=\(context.preparedPortableMessageHashes.count)"
            )
        case .replay(_, let source):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=replay sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) hashes=\(source.portableMessageHashes.count)"
            )
        case .waited(let source):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=waited onGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count)"
            )
        case .leaderFailed(let source, let replay):
            AppLog.proxy.warning(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=leader_failed sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count) status=\(replay?.statusCode ?? 0)"
            )
        }
    }

    // MARK: - Thinking Diagnostics

    /// Log structural metadata about thinking/signature blocks in the request body.
    /// Only logs message indices, roles, block type counts, and signature presence — no content.
    private static func logThinkingDiagnostics(body: Data, requestID: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }

        // Log top-level thinking configuration.
        if let thinking = json["thinking"] as? [String: Any] {
            let thinkingType = thinking["type"] as? String ?? "?"
            let budget = thinking["budget_tokens"] as? Int
            let budgetStr = budget.map { String($0) } ?? "none"
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ThinkingDiag: config thinking.type=\(thinkingType) budget=\(budgetStr)"
            )
        }

        // Log per-message thinking block structure.
        guard let messages = json["messages"] as? [[String: Any]] else { return }
        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String ?? "?"

            // content can be a string or an array of blocks.
            guard let contentArray = message["content"] as? [[String: Any]] else { continue }

            var thinkingCount = 0
            var allHaveSignature = true
            var anyHasSignature = false

            for block in contentArray {
                let blockType = block["type"] as? String ?? ""
                if blockType == "thinking" {
                    thinkingCount += 1
                    if block["signature"] is String {
                        anyHasSignature = true
                    } else {
                        allHaveSignature = false
                    }
                }
            }

            // Only log messages that contain thinking blocks.
            guard thinkingCount > 0 else { continue }
            let sigStatus: String
            if allHaveSignature && anyHasSignature {
                sigStatus = "all-signed"
            } else if anyHasSignature {
                sigStatus = "partial-signed"
            } else {
                sigStatus = "unsigned"
            }
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ThinkingDiag: msg[\(index)] role=\(role) blocks=\(contentArray.count) thinking=\(thinkingCount) sig=\(sigStatus)"
            )
        }
    }

    private static func extractAPIKey(from headers: HTTPHeaders) -> String {
        if let bearer = headers.first(name: "authorization") {
            return bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        }
        return headers.first(name: "x-api-key") ?? ""
    }

    static func sendError(channel: any Channel, status: HTTPResponseStatus, message: String) async {
        await sendResponse(channel: channel, status: status, contentType: "text/plain", body: Data(message.utf8))
    }

    /// Anthropic-shaped JSON error body (relay terminal outcomes — zbridge parity).
    static func sendAnthropicError(
        channel: any Channel, status: HTTPResponseStatus, type: String, message: String
    ) async {
        let body: [String: Any] = [
            "type": "error",
            "error": ["type": type, "message": message]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        await sendResponse(channel: channel, status: status, contentType: "application/json", body: data)
    }

    /// Write a complete proxy-generated response with an explicit `Content-Length`, then close.
    static func sendResponse(
        channel: any Channel,
        status: HTTPResponseStatus,
        contentType: String?,
        body bodyData: Data
    ) async {
        var responseHead = HTTPResponseHead(version: .http1_1, status: status)
        if let contentType {
            responseHead.headers.add(name: "Content-Type", value: contentType)
        }
        responseHead.headers.add(name: "Content-Length", value: "\(bodyData.count)")
        responseHead.headers.add(name: "Connection", value: "close")

        // Queue head and body without awaiting: an unflushed write's future only completes on flush,
        // so awaiting it here would stall before the flush below.
        channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
        if !bodyData.isEmpty {
            var buf = channel.allocator.buffer(capacity: bodyData.count)
            buf.writeBytes(bodyData)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
        }
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.end(nil))
        ).get()
        try? await channel.close().get()
    }

    private static func commitBridgeAssistantTurnIfCurrent(
        _ assistantTurn: PortableAssistantTurn,
        branchContext: PreparedBranchContext,
        branchLease: BranchRequestLease,
        lineageBroker: any SessionLineageBrokering,
        requestCoordinator: any BranchRequestCoordinating,
        requestID: String
    ) async {
        guard await requestCoordinator.shouldCommit(lease: branchLease) else {
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] staleBridgeCommitDropped lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) generation=\(branchLease.generation)"
            )
            return
        }
        do {
            try await lineageBroker.commitResponse(context: branchContext, assistantTurn: assistantTurn)
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] bridgeCommitFailed lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) error=\(String(describing: error))")
        }
    }

    /// Top-level request fields Claude Code sends for Claude models (observed in Claude Code 2.1.282)
    /// that Anthropic-compatible vendors may reject. Claude Code does not retry without them.
    static let claudeOnlyBodyFields = ["context_management", "output_config", "safeguards", "speed", "thread"]
    /// Tool-definition fields tied to Anthropic betas.
    static let claudeOnlyToolFields = ["strict", "defer_loading", "eager_input_streaming"]

    struct ClaudeOnlyFieldStripResult {
        let bodyData: Data
        let removedFields: [String]
    }

    /// Opt-in per vendor. The body is re-serialized only when a field was actually removed.
    static func stripClaudeOnlyRequestFields(in bodyData: Data) -> ClaudeOnlyFieldStripResult {
        guard var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return ClaudeOnlyFieldStripResult(bodyData: bodyData, removedFields: [])
        }
        var removed: [String] = []
        for field in claudeOnlyBodyFields where json.removeValue(forKey: field) != nil {
            removed.append(field)
        }
        if let tools = json["tools"] as? [[String: Any]] {
            var removedToolFields: Set<String> = []
            json["tools"] = tools.map { tool in
                var tool = tool
                for field in claudeOnlyToolFields where tool.removeValue(forKey: field) != nil {
                    removedToolFields.insert(field)
                }
                return tool
            }
            removed += removedToolFields.sorted().map { "tools[].\($0)" }
        }
        guard !removed.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return ClaudeOnlyFieldStripResult(bodyData: bodyData, removedFields: [])
        }
        return ClaudeOnlyFieldStripResult(bodyData: encoded, removedFields: removed)
    }

    /// Remove tool definitions that mapped vendors cannot handle.
    /// Keeps only tools with a non-empty `name` and a present `input_schema` —
    /// the Anthropic Messages API contract for custom (user-defined) tools.
    /// Server-side tools (web_search, computer_use, etc.) use `type` instead
    /// of `name` + `input_schema`, so they are naturally excluded.
    static func sanitizeToolsForVendor(in bodyData: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]] else {
            return bodyData
        }
        let filtered = tools.filter { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return false }
            guard tool["input_schema"] != nil else { return false }
            return true
        }
        let removedCount = tools.count - filtered.count
        guard removedCount > 0 else { return bodyData }
        let removedNames = tools.filter { tool in
            let name = tool["name"] as? String ?? ""
            let hasSchema = tool["input_schema"] != nil
            return name.isEmpty || !hasSchema
        }.map { ($0["type"] as? String) ?? ($0["name"] as? String) ?? "unknown" }
        AppLog.proxy.info("[Proxy] sanitizeToolsForVendor: removed \(removedCount) tools: \(removedNames.joined(separator: ", "))")
        if filtered.isEmpty {
            json.removeValue(forKey: "tools")
            json.removeValue(forKey: "tool_choice")
        } else {
            json["tools"] = filtered
        }
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? bodyData
    }
}
