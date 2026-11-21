import Testing
@testable import ZGate

/// TrafficEntry display columns (wave-2 polish, 2026-11-21): the off-peak
/// route label, the input-size column, and tok/s derivability.
@Suite("TrafficLog display")
struct TrafficLogDisplayTests {

    @Test("off-peak route label names the wire model")
    func offPeakRouteLabel() {
        let withModel = TrafficEntry(
            model: "glm-5.3", routeType: .offPeak(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200)
        #expect(withModel.routeDisplayLabel == "GLM-5.3 · off-peak")
        #expect(withModel.classTargetDisplayLabel == "opus → GLM-5.3 · off-peak")

        let withoutModel = TrafficEntry(
            model: "glm-5.3", routeType: .offPeak(targetModel: nil),
            requestKind: .generation, httpStatus: 200)
        #expect(withoutModel.routeDisplayLabel == "off-peak")
    }

    @Test("input-token size column formats compactly")
    func inputTokensDisplay() {
        let none = TrafficEntry(
            model: "m", routeType: .mapped(targetModel: "m"),
            requestKind: .generation, httpStatus: 200)
        #expect(none.inputTokensDisplayText == "—")

        let small = TrafficEntry(
            model: "m", routeType: .mapped(targetModel: "m"),
            requestKind: .generation, httpStatus: 200, inputTokens: 940)
        #expect(small.inputTokensDisplayText == "940")

        let kilo = TrafficEntry(
            model: "m", routeType: .mapped(targetModel: "m"),
            requestKind: .generation, httpStatus: 200, inputTokens: 30_240)
        #expect(kilo.inputTokensDisplayText == "30.2K")

        let mega = TrafficEntry(
            model: "m", routeType: .mapped(targetModel: "m"),
            requestKind: .generation, httpStatus: 200, inputTokens: 2_400_000)
        #expect(mega.inputTokensDisplayText == "2.4M")
    }

    @Test("tok/s derivable once ttft is present — off-peak rows included")
    func tokensPerSecondWithTTFT() {
        // No ttft (previously every off-peak row): "—".
        let noTTFT = TrafficEntry(
            model: "m", routeType: .offPeak(targetModel: "m"),
            requestKind: .generation, httpStatus: 200,
            duration: 10, ttft: nil, outputTokens: 500, inputTokens: 1_000)
        #expect(noTTFT.tokensPerSecondDisplayText == "—")

        // Streaming window (ttft < duration): tokens / (duration - ttft).
        let streamed = TrafficEntry(
            model: "m", routeType: .offPeak(targetModel: "m"),
            requestKind: .generation, httpStatus: 200,
            duration: 12, ttft: 2, outputTokens: 500, inputTokens: 1_000)
        #expect(streamed.tokensPerSecondDisplayText == "50")
    }
}
