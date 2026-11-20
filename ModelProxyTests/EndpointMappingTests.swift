import Foundation
import Testing
@testable import ZGate

/// Pure tests for `EndpointMapping` — the CLI's
/// ProviderEndpointRoutingService mapping rules (zcode.cjs 0.17.1,
/// P_t/Iha/Aha/xha/xvo), no network. Every rejection drops the WHOLE
/// mapping: server-driven routing must never half-apply a hostile table.
struct EndpointMappingTests {

    /// One-entry envelope builder; `flag` nil = entry without the header key.
    private func payload(_ from: String, _ to: String, flag: String? = nil) throws -> Data {
        var entry: [String: Any] = ["from": from, "to": to]
        if let flag { entry["zcodeAuthorizationHeader"] = flag }
        return try envelope(mapping: [entry])
    }

    private func envelope(mapping: [[String: Any]], code: Any = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "code": code,
            "data": ["proxyEndpoint": ["mapping": mapping]],
        ])
    }

    private static let preRouting = "https://zcode.z.ai/api/v1/zcode-plan/anthropic"
    private static let ultraTarget = "https://zcode.z.ai/api/v1/ultra-zai/anthropic"

    // MARK: - Valid shapes

    @Test func validFlaggedMappingRewritesURLAndFlagsAuthorization() throws {
        let mapping = try #require(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget, flag: "X-ZCode-Authorization")))
        let resolved = try #require(mapping.resolve(
            "https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages?beta=1"))
        #expect(resolved.url == "https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages?beta=1")
        #expect(resolved.addZcodeAuthorization)
    }

    @Test func unflaggedMappingRewritesWithoutAuthorization() throws {
        let mapping = try #require(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget)))
        let resolved = try #require(mapping.resolve(
            "https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages"))
        #expect(resolved.url == "https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages")
        #expect(!resolved.addZcodeAuthorization)
    }

    /// From is a path PREFIX of the request at a segment boundary — the AC's
    /// own example (from …/anthropic, request …/anthropic/v1/messages).
    @Test func exactAllowlistedFlaggedTargetsParse() throws {
        // The two bare allowlist paths themselves (origin + path check).
        for path in ["/api/v1/ultra", "/api/v1/ultra-zai"] {
            let mapping = try #require(EndpointMapping.parse(
                try payload(Self.preRouting, "https://zcode.z.ai\(path)", flag: "X-ZCode-Authorization")))
            #expect(mapping.entries.count == 1)
            #expect(mapping.entries[0].flaggedForZcodeAuthorization)
        }
        // Segment boundaries: /api/v1/ultra-zai/anthropic rides the
        // /api/v1/ultra-zai prefix, but /api/v1/ultraviolet matches neither.
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, "https://zcode.z.ai/api/v1/ultraviolet",
                        flag: "X-ZCode-Authorization")) == nil)
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, "https://zcode.z.ai/api/v1/ultra/anthropic",
                        flag: "X-ZCode-Authorization")) != nil)
    }

    // MARK: - Lookup insensitivity

    @Test func trailingSlashesAreStrippedForLookup() throws {
        // `from` carrying a trailing slash still matches the bare request.
        let mapping = try #require(EndpointMapping.parse(
            try payload(Self.preRouting + "/", Self.ultraTarget)))
        #expect(mapping.resolve("https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages") != nil)
        // A trailing-slash request (exactly the from path + "/") matches too.
        let resolved = try #require(mapping.resolve("https://zcode.z.ai/api/v1/zcode-plan/anthropic/"))
        #expect(resolved.url == Self.ultraTarget)
    }

    @Test func defaultPort443NormalizesAgainstExplicitPort() throws {
        // from with an explicit :443 matches the port-less request form.
        let mapping = try #require(EndpointMapping.parse(
            try payload("https://zcode.z.ai:443/api/v1/zcode-plan/anthropic", Self.ultraTarget)))
        #expect(mapping.resolve("https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages") != nil)
        // A non-443 port is a different key — no accidental match.
        #expect(mapping.resolve("https://zcode.z.ai:8443/api/v1/zcode-plan/anthropic/v1/messages") == nil)
    }

    @Test func nonMatchingURLOffersNoRewrite() throws {
        let mapping = try #require(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget)))
        #expect(mapping.resolve("https://other.example/x") == nil)
        #expect(mapping.resolve("https://zcode.z.ai/api/v1/elsewhere/v1/messages") == nil)
        #expect(mapping.resolve("not a url") == nil)
    }

    // MARK: - Rejections (each drops the whole mapping)

    @Test func rejectsNonHTTPS() throws {
        #expect(EndpointMapping.parse(try payload("http://zcode.z.ai/api/v1/a", Self.ultraTarget)) == nil)
        #expect(EndpointMapping.parse(try payload(Self.preRouting, "http://zcode.z.ai/api/v1/ultra-zai/anthropic")) == nil)
    }

    @Test func rejectsUserinfoQueryFragment() throws {
        #expect(EndpointMapping.parse(try payload(
            "https://user:pass@zcode.z.ai/api/v1/a", Self.ultraTarget)) == nil)
        #expect(EndpointMapping.parse(try payload(
            Self.preRouting, "https://zcode.z.ai/api/v1/ultra-zai/anthropic?q=1")) == nil)
        #expect(EndpointMapping.parse(try payload(
            Self.preRouting, "https://zcode.z.ai/api/v1/ultra-zai/anthropic#frag")) == nil)
    }

    @Test func rejectsDuplicateFrom() throws {
        let entry: [String: Any] = ["from": Self.preRouting, "to": Self.ultraTarget]
        // Literal duplicate...
        #expect(EndpointMapping.parse(try envelope(mapping: [entry, entry])) == nil)
        // ...and the trailing-slash form of the same lookup key.
        let slashed: [String: Any] = ["from": Self.preRouting + "/", "to": Self.ultraTarget]
        #expect(EndpointMapping.parse(try envelope(mapping: [entry, slashed])) == nil)
    }

    @Test func rejectsOversizedTable() throws {
        let mapping = (0...256).map { i -> [String: Any] in
            ["from": "https://zcode.z.ai/api/v1/p\(i)", "to": Self.ultraTarget]
        }
        #expect(EndpointMapping.parse(try envelope(mapping: mapping)) == nil)
        // 256 exactly is fine.
        let exact = Array(mapping.dropLast())
        #expect(EndpointMapping.parse(try envelope(mapping: exact))?.entries.count == 256)
    }

    @Test func rejectsOversizedBody() throws {
        let big = try payload(Self.preRouting, Self.ultraTarget)
        var padded = big
        padded.append(Data(repeating: 0x20, count: 256 * 1024 + 1))
        #expect(EndpointMapping.parse(padded) == nil)
    }

    @Test func rejectsFlagOnDisallowedTarget() throws {
        // Foreign origin, allowlisted path.
        #expect(EndpointMapping.parse(try payload(
            Self.preRouting, "https://api.z.ai/api/v1/ultra", flag: "X-ZCode-Authorization")) == nil)
        // Right origin, foreign path.
        #expect(EndpointMapping.parse(try payload(
            Self.preRouting, "https://zcode.z.ai/api/v1/other", flag: "X-ZCode-Authorization")) == nil)
        // Right origin + a NON-FLAGGED entry may target anywhere https.
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, "https://api.z.ai/api/v1/elsewhere")) != nil)
    }

    @Test func rejectsWrongAuthorizationHeaderName() throws {
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget, flag: "X-ZCode-Other")) == nil)
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget, flag: "")) == nil)
        // Case-insensitive literal match is the CLI's own tolerance.
        #expect(EndpointMapping.parse(
            try payload(Self.preRouting, Self.ultraTarget, flag: "x-zcode-authorization")) != nil)
    }

    @Test func rejectsNonZeroEnvelopeCode() throws {
        #expect(EndpointMapping.parse(try envelope(mapping: [], code: 42)) == nil)
        // A missing envelope code is not success either.
        let bare = try JSONSerialization.data(withJSONObject: [
            "data": ["proxyEndpoint": ["mapping": []]],
        ])
        #expect(EndpointMapping.parse(bare) == nil)
    }
}
