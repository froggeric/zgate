import CryptoKit
import Foundation
import Testing
@testable import ZGate

struct CryptoCoreTests {

    // MARK: HKDF (RFC 5869, SHA-256)

    @Test func testHKDFRFCVector() {
        // RFC 5869 Test Case 1 (SHA-256): IKM = 0x0b × 22, salt = 000102030405060708090a0b0c, info = f0f1f2f3f4f5f6f7f8f9, L = 42
        let ikm  = Data(repeating: 0x0b, count: 22)
        let salt = Data([0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c])
        let info = Data([0xf0,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9])
        let okm = CryptoCore.hkdf(ikm: ikm, salt: salt, info: info, length: 42)
        #expect(okm.count == 42)
        #expect(okm.map { String(format: "%02x", $0) }.joined() ==
                "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    @Test func testHKDFRFCVectorEmptySaltAndInfo() {
        // RFC 5869 Test Case 3 (SHA-256): IKM = 0x0b × 22, salt and info empty, L = 42.
        // Exercises the RFC §2.2 rule that an absent salt becomes HashLen zeros.
        let ikm = Data(repeating: 0x0b, count: 22)
        let okm = CryptoCore.hkdf(ikm: ikm, salt: Data(), info: Data(), length: 42)
        #expect(okm.map { String(format: "%02x", $0) }.joined() ==
                "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    }

    // MARK: Signing messages

    @Test func testHandshakeSigMessageFormat() {
        let message = CryptoCore.handshakeSigMessage(apiKeyId: "b5f4e699", ts: "1760000000000", nonce: "00112233445566778899aabbccddeeff")
        #expect(message == "get_sign_key\nb5f4e699\n1760000000000\n00112233445566778899aabbccddeeff")
    }

    @Test func testRequestSigMessageFormat() {
        let message = CryptoCore.requestSigMessage(
            apiKeyId: "b5f4e699888920",
            ts: "1760000000000",
            version: "0.17.1",
            sessionId: "6f9619ff-8b86-d011-b42d-00cf4fc964ff",
            nonce: "00112233445566778899aabbccddeeff"
        )
        #expect(message ==
                "b5f4e699888920\n1760000000000\n0.17.1\n6f9619ff-8b86-d011-b42d-00cf4fc964ff\n00112233445566778899aabbccddeeff")
    }

    // MARK: Handshake HMAC

    @Test func testHandshakeHmacIs64Hex() {
        let credential = Data("fake-project-access-token".utf8)
        let key = CryptoCore.hkdf(
            ikm: credential,
            salt: Data(CryptoCore.kdfSalt.utf8),
            info: Data(CryptoCore.hmacInfo.utf8),
            length: 32
        )
        let message = CryptoCore.handshakeSigMessage(
            apiKeyId: "b5f4e6998889200000000000000088920",
            ts: "1760000000000",
            nonce: "00112233445566778899aabbccddeeff"
        )
        let sig = CryptoCore.hmacHex(message: message, key: key)
        #expect(sig.count == 64)
        #expect(sig.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        // Deterministic: same inputs, same hex.
        #expect(CryptoCore.hmacHex(message: message, key: key) == sig)
    }

    @Test func testHandshakeHmacBase64Is44Chars() throws {
        let credential = Data("fake-project-access-token".utf8)
        let key = CryptoCore.hkdf(
            ikm: credential,
            salt: Data(CryptoCore.kdfSalt.utf8),
            info: Data(CryptoCore.hmacInfo.utf8),
            length: 32
        )
        let message = CryptoCore.handshakeSigMessage(
            apiKeyId: "b5f4e6998889200000000000000088920",
            ts: "1760000000000",
            nonce: "00112233445566778899aabbccddeeff"
        )
        // Raw HMAC is the 32-byte HMAC-SHA256 output.
        #expect(CryptoCore.hmac(message: message, key: key).count == 32)
        // Wire form (live capture): base64, 44 chars — one per 3 bytes of the 32-byte MAC.
        let sig = CryptoCore.hmacBase64(message: message, key: key)
        #expect(sig.count == 44)
        let bytes = try #require(Data(base64Encoded: sig))
        #expect(bytes.count == 32)
        // Both encodings carry the same MAC bytes.
        #expect(bytes.map { String(format: "%02x", $0) }.joined() == CryptoCore.hmacHex(message: message, key: key))
    }

    // MARK: Proof of work

    @Test func testPowFindsLeadingZeroHash() throws {
        let nonce = "00112233445566778899aabbccddeeff"
        let ts = "1760000000000"
        let pow = CryptoCore.pow(nonce: nonce, ts: ts)
        let value = try #require(pow)
        #expect(value.count == 32)
        #expect(value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        // Independent check: the digest of the exact PoW message starts with a zero byte.
        let digest = SHA256.hash(data: Data(CryptoCore.powMessage(nonce: nonce, ts: ts, pow: value).utf8))
        #expect(digest.starts(with: [UInt8(0)]))
        // Round-trip through the verifier.
        #expect(CryptoCore.verifyPow(nonce: nonce, ts: ts, pow: value))
    }

    @Test func testPowRespectsAttemptBound() {
        #expect(CryptoCore.pow(nonce: "00112233445566778899aabbccddeeff", ts: "1760000000000", maxAttempts: 0) == nil)
    }

    @Test func testVerifyPowRejectsNonSolutions() throws {
        let nonce = "00112233445566778899aabbccddeeff"
        let ts = "1760000000000"
        // Find a tampered 32-hex value whose PoW message does NOT start with a zero byte
        // (picking the first of a few deterministic candidates guarantees one exists).
        let bad = try #require((0..<64).compactMap { i -> String? in
            let candidate = String(format: "%032d", i)
            let digest = SHA256.hash(data: Data(CryptoCore.powMessage(nonce: nonce, ts: ts, pow: candidate).utf8))
            return digest.starts(with: [UInt8(0)]) ? nil : candidate
        }.first)
        #expect(!CryptoCore.verifyPow(nonce: nonce, ts: ts, pow: bad))
        // Malformed inputs are not solutions either.
        #expect(!CryptoCore.verifyPow(nonce: nonce, ts: ts, pow: "tooshort"))
    }

    // MARK: Ed25519 request signature

    @Test func testEd25519SignatureIs88CharBase64() throws {
        // Message built from fixture-scale field sizes: 32-hex apiKeyId, 13-digit ts,
        // client version, 36-char session id, 32-hex nonce.
        let message = CryptoCore.requestSigMessage(
            apiKeyId: "b5f4e6998889200000000000000088920",
            ts: "1760000000000",
            version: "0.17.1",
            sessionId: "6f9619ff-8b86-d011-b42d-00cf4fc964ff",
            nonce: "00112233445566778899aabbccddeeff"
        )
        let key = Curve25519.Signing.PrivateKey()
        let sig = try CryptoCore.sign(message: Data(message.utf8), privateKey: key)
        #expect(sig.count == 88)  // base64 of the 64-byte Ed25519 signature, matching observed x-client-sig length
        let sigBytes = try #require(Data(base64Encoded: sig))
        #expect(sigBytes.count == 64)
        #expect(key.publicKey.isValidSignature(sigBytes, for: Data(message.utf8)))
    }
}
