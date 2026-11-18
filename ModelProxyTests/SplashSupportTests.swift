import Foundation
import Testing
@testable import ZGate

@Suite struct SplashSupportTests {
    @Test func backoffSequenceCaps() {
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 60]
        #expect((1...8).map { SplashBackoff.delay(attempt: $0) } == expected)
        #expect(SplashBackoff.delay(attempt: 0) == 0)
        #expect(SplashBackoff.stableReset == 300)
    }

    @Test func ringBufferTrimsFrontKeepsOrder() {
        var ring = LogRingBuffer(capacity: 3)
        for i in 1...5 { ring.append("line \(i)") }
        #expect(ring.lines == ["line 3", "line 4", "line 5"])
    }

    @Test func ringBufferClampsCapacity() {
        var ring = LogRingBuffer(capacity: 0)
        ring.append("a"); ring.append("b")
        #expect(ring.lines == ["b"])
        #expect(LogRingBuffer.defaultCapacity == 500)
    }
}
