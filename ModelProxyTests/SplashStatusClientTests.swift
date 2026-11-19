import Foundation
import Testing
@testable import ZGate

/// `/status` → `disk` decode (spec §2/§3.6): full fixture, minimal
/// fixture, malformed → nil. The fetch seam carries the payload — no
/// network anywhere in these tests.
@Suite struct SplashStatusClientTests {

    @Test func decodesFullDisk() async throws {
        let json = #"{"disk":{"capacity_bytes":21474836480,"limit_bytes":18000000000,"used_bytes":123,"file_bytes":130,"volume_available_bytes":999,"writes_gated":"no","persistent":true,"taken_back":1}}"#
        let client = SplashStatusClient(fetch: { _ in Data(json.utf8) })
        let d = try #require(await client.diskStatus(port: 8123))
        #expect(d.capacityBytes == 21_474_836_480)
        #expect(d.limitBytes == 18_000_000_000)
        #expect(d.usedBytes == 123)
        #expect(d.fileBytes == 130)
        #expect(d.volumeAvailableBytes == 999)
        #expect(d.writesGated == "no")
        #expect(d.persistent == true)
        // `taken_back` is a real /status field we don't surface yet —
        // tolerant decode must ignore it, not fail.
    }

    @Test func minimalDiskDecodesWithNilFields() async throws {
        // `{"disk":{}}` → non-nil with all-nil fields is fine; the usage
        // row simply omits what splash didn't report.
        let client = SplashStatusClient(fetch: { _ in Data(#"{"disk":{}}"#.utf8) })
        let d = try #require(await client.diskStatus(port: 8123))
        #expect(d.capacityBytes == nil && d.usedBytes == nil && d.persistent == nil)
    }

    @Test func malformedPayloadReturnsNil() async {
        let client = SplashStatusClient(fetch: { _ in Data("not json".utf8) })
        #expect(await client.diskStatus(port: 8123) == nil)
    }

    @Test func envelopeWithoutDiskReturnsNil() async {
        let client = SplashStatusClient(fetch: { _ in Data(#"{"uptime":12}"#.utf8) })
        #expect(await client.diskStatus(port: 8123) == nil)
    }

    @Test func fetchFailureReturnsNil() async {
        struct Boom: Error {}
        let client = SplashStatusClient(fetch: { _ in throw Boom() })
        #expect(await client.diskStatus(port: 8123) == nil)
    }

    @Test func endpointDerivesFromPort() {
        #expect(SplashStatusClient.endpoint(port: 8123).absoluteString == "http://127.0.0.1:8123/status")
    }
}
