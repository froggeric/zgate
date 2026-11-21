import Foundation
import Testing
@testable import ZGate

/// Pair-preserving strip of auto mode's server-side-review `safeguards` field
/// on the relay plane: the relay face rebuilds headers, so the paired
/// `anthropic-beta` value never rides and the field must not ride alone
/// (`ProxyForwarder.forward` applies this for `.relay` targets).
/// `stripSafeguardsField` is byte surgery — every byte outside the removed
/// member must survive untouched.
struct SafeguardsPairStripTests {

    // MARK: - Member removal, comma handling

    @Test func stripsMiddleMemberKeepingOtherBytesIdentical() {
        let body = #"{"model":"glm-5.3[1m]","safeguards":{"type":"auto_mode"},"max_tokens":8}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{"model":"glm-5.3[1m]","max_tokens":8}"#)
    }

    @Test func stripsFirstMemberWithFollowingComma() {
        let body = #"{"safeguards":{"a":1},"model":"m"}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{"model":"m"}"#)
    }

    @Test func stripsLastMemberWithLeadingComma() {
        let body = #"{"model":"m","safeguards":[1,2,3]}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{"model":"m"}"#)
    }

    @Test func stripsSoleMemberLeavingEmptyObject() {
        let body = #"{"safeguards":{}}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{}"#)
    }

    @Test func handlesWhitespaceAroundMember() {
        let body = #"{ "model" : "m" , "safeguards" : { "a" : 1 } , "stream" : true }"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{ "model" : "m" ,  "stream" : true }"#)
    }

    // MARK: - Value types

    @Test func stripsScalarAndLiteralValues() {
        for value in ["\"x\"", "true", "false", "null", "5", "-1.5e3"] {
            let body = #"{"model":"m","safeguards":\#(value),"stream":true}"#
            let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
            #expect(
                String(decoding: stripped, as: UTF8.self) == #"{"model":"m","stream":true}"#,
                "value \(value) was not stripped cleanly"
            )
        }
    }

    @Test func stripsNestedCompositeValueCompletely() {
        let body = #"{"model":"m","safeguards":{"inner":{"deep":[1,{"k":"v,"}]},"x":null},"stream":true}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == #"{"model":"m","stream":true}"#)
    }

    // MARK: - Non-top-level occurrences untouched

    @Test func leavesNestedSafeguardsKeysAlone() {
        let body = #"{"metadata":{"safeguards":"keep"},"safeguards":{"drop":true},"model":"m"}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(
            String(decoding: stripped, as: UTF8.self)
                == #"{"metadata":{"safeguards":"keep"},"model":"m"}"#
        )
    }

    @Test func leavesSafeguardsInsideMessageContentStringsAlone() {
        // The word appears both as raw JSON text inside a string value and as
        // an escaped nested object; only the top-level member may go.
        let body = #"{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"{\"safeguards\":1} safeguards"}]}],"safeguards":true}"#
        let stripped = ProxyForwarder.stripSafeguardsField(in: Data(body.utf8))
        #expect(
            String(decoding: stripped, as: UTF8.self)
                == #"{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"{\"safeguards\":1} safeguards"}]}]}"#
        )
    }

    // MARK: - No-op paths

    @Test func absentFieldReturnsIdenticalBytes() {
        let body = #"{"model":"glm-5.3[1m]","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}"#
        let original = Data(body.utf8)
        let stripped = ProxyForwarder.stripSafeguardsField(in: original)
        #expect(stripped == original)
    }

    @Test func unscannableBodyReturnsIdenticalBytes() {
        let original = Data("not json at all".utf8)
        #expect(ProxyForwarder.stripSafeguardsField(in: original) == original)
        let truncated = Data(#"{"model":"m","safeguards":{"a":"#.utf8)
        #expect(ProxyForwarder.stripSafeguardsField(in: truncated) == truncated)
    }

    @Test func emptyBodyReturnsIdenticalBytes() {
        let original = Data()
        #expect(ProxyForwarder.stripSafeguardsField(in: original) == original)
    }
}
