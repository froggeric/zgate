import Foundation
import Testing
@testable import ZGate

/// Task 6: the business-code error taxonomy — classification of drained
/// upstream error envelopes from PARSED JSON only. Substring matching over
/// raw bodies is forbidden by design: 20-digit logids contain every
/// 4-digit code as a substring, so `logid …1113…3009…` must never turn a
/// rate limit into quota exhaustion or a concurrency block.
@Suite
struct RelayErrorTaxonomyTests {

    // MARK: - Envelope parsing (AC: {code, msg|message}, {error:{message, code}}, {error:{type,message}})

    private func parsed(_ json: [String: Any], status: Int = 400) throws -> RelayUpstreamError {
        try #require(RelayUpstreamError.parse(
            status: status, body: JSONSerialization.data(withJSONObject: json)))
    }

    @Test func parseExtractsTopLevelCodeAndMsg() throws {
        let error = try parsed(["code": 1302, "msg": "rate limited, logid 11139999999999993009"], status: 429)
        #expect(error.status == 429)
        #expect(error.code == 1302)
        #expect(error.message == "rate limited, logid 11139999999999993009")
    }

    @Test func parseExtractsTopLevelCodeAndMessage() throws {
        let error = try parsed(["code": 3006, "message": "model not allowed"])
        #expect(error.code == 3006)
        #expect(error.message == "model not allowed")
    }

    @Test func parseExtractsNestedErrorCodeAndMessage() throws {
        let error = try parsed(["error": ["code": 1113, "message": "insufficient balance"]])
        #expect(error.code == 1113)
        #expect(error.message == "insufficient balance")
    }

    @Test func parseAnthropicErrorShapeCarriesMessageButNoCode() throws {
        // `{error:{type,message}}` — the Anthropic shape: a message for the
        // 401 ladder / passthrough surfaces, but no business code.
        let error = try parsed(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        #expect(error.code == nil)
        #expect(error.message == "rate limited")
        // No code → status ladder only → a 429 stays unclassified.
        #expect(RelayErrorTaxonomy.classify(error) == .unclassified)
    }

    @Test func parseRejectsNonJSONObjectBodies() throws {
        #expect(RelayUpstreamError.parse(status: 400, body: Data("[1,2]".utf8)) == nil)
        #expect(RelayUpstreamError.parse(status: 400, body: Data("\"nope\"".utf8)) == nil)
        #expect(RelayUpstreamError.parse(status: 400, body: Data("not json".utf8)) == nil)
        #expect(RelayUpstreamError.parse(status: 400, body: Data()) == nil)
    }

    @Test func parseRejectsBooleanCodeAcceptsNumericString() throws {
        // Booleans are not numbers (the MonitorEnvelope discipline); a
        // numeric string IS a code (SigningClient's numberField parity).
        #expect(try parsed(["code": true, "msg": "x"]).code == nil)
        let stringCode = try parsed(["code": "1302", "msg": "x"])
        #expect(stringCode.code == 1302)
    }

    // MARK: - Classification table (AC: every code, status fallbacks, 1114 absent)

    @Test func classificationTableMapsEveryBusinessCode() {
        let table: [(code: Int, kind: RelayFailureKind)] = [
            (1005, .quotaExhausted), (1113, .quotaExhausted), (1310, .quotaExhausted),
            (1302, .rateLimited), (1303, .rateLimited),
            (3008, .concurrencyLimited), (3009, .concurrencyLimited), (3010, .concurrencyLimited),
            (3012, .riskControl),
            (3007, .captchaChallenge),
            (3006, .modelNotAllowed),
            (1210, .invalidParameter), (3001, .invalidParameter),
        ]
        for row in table {
            #expect(
                RelayErrorTaxonomy.classify(RelayUpstreamError(status: 400, code: row.code, message: "m"))
                    == row.kind)
        }
    }

    @Test func statusFallbacks402And405ApplyWithoutACode() {
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 402, code: nil, message: nil))
            == .quotaExhausted)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 405, code: nil, message: nil))
            == .riskControl)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: nil, message: nil))
            == .unclassified)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 400, code: nil, message: nil))
            == .unclassified)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 500, code: nil, message: nil))
            == .unclassified)
    }

    @Test func unknownCodeFallsThroughToTheStatusLadder() {
        // A code the table does not know is not an error of classification:
        // the status fallbacks still apply (402/405), else unclassified.
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 402, code: 9999, message: nil))
            == .quotaExhausted)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 500, code: 9999, message: nil))
            == .unclassified)
    }

    @Test func codeBeatsStatusWhenBothWouldClassify() {
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 402, code: 1302, message: nil))
            == .rateLimited)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 405, code: 3008, message: nil))
            == .concurrencyLimited)
    }

    @Test func code1114IsNeverClassified() {
        // 1114 does not exist upstream (peer ruling): whatever carries it,
        // it must not land in a remediation class.
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 400, code: 1114, message: "m"))
            == .unclassified)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: 1114, message: "m"))
            == .unclassified)
    }

    // MARK: - The logid collision (AC: parsed code only, never substrings)

    @Test func testLogidCollisionDoesNotMisclassify() {
        let e = RelayUpstreamError(status: 429, code: 1302,
            message: "rate limited, logid 11139999999999993009")
        #expect(RelayErrorTaxonomy.classify(e) == .rateLimited)  // not exhausted/concurrency
    }

    @Test func collidingLogidsNeverChangeAnyClass() {
        // The same 20-digit logid rides every message: classification
        // follows the parsed code alone.
        let logid = "logid 3008111310059913123009"
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: 1005, message: logid))
            == .quotaExhausted)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: 3008, message: logid))
            == .concurrencyLimited)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: 3012, message: logid))
            == .riskControl)
        #expect(RelayErrorTaxonomy.classify(RelayUpstreamError(status: 429, code: nil, message: logid))
            == .unclassified)
    }

    // MARK: - 200 business-envelope detection (AC: code != 0, no type:"message")

    private func data(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    @Test func businessEnvelopeRequiresNonZeroTopLevelCode() throws {
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: try data(["code": 1302, "msg": "x"]))
            != nil)
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: try data(["code": 0, "msg": "ok"]))
            == nil)
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: try data(["msg": "no code"])) == nil)
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: try data(["code": true])) == nil)
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: Data("not json".utf8)) == nil)
    }

    @Test func anthropicSuccessShapeIsNotABusinessEnvelope() throws {
        // A non-streaming Anthropic success IS JSON — but it carries
        // `type`/`id`, never a top-level business `code`.
        let success = try data([
            "id": "msg_1", "type": "message", "role": "assistant",
            "content": [["type": "text", "text": "héllo"]],
        ])
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: success) == nil)
        // Even a hybrid carrying `type:"message"` stays a success.
        let hybrid = try data(["type": "message", "code": 1302])
        #expect(RelayErrorTaxonomy.businessEnvelope(status: 200, body: hybrid) == nil)
    }

    @Test func businessEnvelopeCarriesTheParsedCodeAndMessage() throws {
        let envelope = try #require(RelayErrorTaxonomy.businessEnvelope(
            status: 200, body: try data(["code": 1113, "msg": "insufficient quota"])))
        #expect(envelope.code == 1113)
        #expect(envelope.message == "insufficient quota")
        #expect(RelayErrorTaxonomy.classify(envelope) == .quotaExhausted)
    }

    // MARK: - Display reason (logs and proxy-authored terminals)

    @Test func displayReasonPrefersMessageThenCodeThenStatus() {
        #expect(RelayUpstreamError(status: 429, code: 1302, message: "rate limited").displayReason
            == "rate limited")
        #expect(RelayUpstreamError(status: 429, code: 1302, message: nil).displayReason
            == "business code 1302")
        #expect(RelayUpstreamError(status: 405, code: nil, message: nil).displayReason == "HTTP 405")
        #expect(RelayUpstreamError(status: 405, code: nil, message: "").displayReason == "HTTP 405")
    }
}
