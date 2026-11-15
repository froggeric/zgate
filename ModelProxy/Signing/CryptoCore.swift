import CryptoKit
import Foundation

/// Pure signing math for the zcode relay client-signing protocol (V4).
///
/// No network, no state — every member is a deterministic function of its inputs.
/// Callers build the wire requests; these helpers do the key derivation, message
/// framing, proof-of-work, and signature math they need.
enum CryptoCore {

    // MARK: Key-schedule constants (pinned from the zcode CLI bundle)

    /// HKDF salt for the client-signing key schedule.
    nonisolated static let kdfSalt = "WD_CLIENT_SIGN_KDF_SALT"
    /// HKDF info for the handshake HMAC key.
    nonisolated static let hmacInfo = "getSignKey_hmac"
    /// HKDF info for the handshake-derived Ed25519 private key (consumed by SigningClient).
    nonisolated static let ed25519Info = "ed25519_priv"

    // MARK: HKDF (RFC 5869, SHA-256)

    /// Extract-and-expand HKDF with SHA-256 (CryptoKit has no HKDF).
    ///
    /// An empty `salt` follows RFC 5869 §2.2 and is replaced by HashLen zero bytes.
    nonisolated static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        precondition(length > 0, "HKDF output length must be positive")
        precondition(length <= 255 * SHA256Digest.byteCount, "HKDF output exceeds 255 blocks")

        // Extract: PRK = HMAC-SHA256(salt, IKM)
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: SHA256Digest.byteCount) : salt
        let prk = hmac(ikm, key: effectiveSalt)

        // Expand: T(i) = HMAC-SHA256(PRK, T(i-1) || info || i), OKM = T(1)…T(n) truncated to length
        var okm = Data()
        var block = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            block.append(info)
            block.append(counter)
            block = hmac(block, key: prk)
            okm.append(block)
            counter &+= 1
        }
        return okm.prefix(length)
    }

    // MARK: Signing messages

    /// Message signed by the handshake request's `sig` field.
    nonisolated static func handshakeSigMessage(apiKeyId: String, ts: String, nonce: String) -> String {
        "get_sign_key\n\(apiKeyId)\n\(ts)\n\(nonce)"
    }

    /// Message signed by the relay request's `X-Client-Sig` header.
    nonisolated static func requestSigMessage(apiKeyId: String, ts: String, version: String, sessionId: String, nonce: String) -> String {
        "\(apiKeyId)\n\(ts)\n\(version)\n\(sessionId)\n\(nonce)"
    }

    // MARK: HMAC

    /// HMAC-SHA256 of `message` (UTF-8) under `key`, as lowercase hex (64 chars).
    nonisolated static func hmacHex(message: String, key: Data) -> String {
        hex(hmac(Data(message.utf8), key: key))
    }

    // MARK: Proof of work

    /// Finds a 32-hex proof whose PoW message hashes (SHA-256) to at least
    /// `leadingZeroBits` leading zero bits. Expected attempts are 2^8 = 256
    /// at the protocol's 8 bits; the default bound allows 32× that headroom.
    /// Returns nil if no proof is found within `maxAttempts`.
    nonisolated static func pow(nonce: String, ts: String, maxAttempts: Int = 1 << 13) -> String? {
        for attempt in 0..<max(0, maxAttempts) {
            let candidate = String(hex(sha256(Data("\(nonce)\n\(ts)\n\(attempt)".utf8))).prefix(32))
            let digest = sha256(Data(powMessage(nonce: nonce, ts: ts, pow: candidate).utf8))
            if hasLeadingZeroBits(digest, bits: leadingZeroBitBudget) { return candidate }
        }
        return nil
    }

    /// Verifies a 32-hex proof against the same PoW message `pow(nonce:ts:)` builds.
    nonisolated static func verifyPow(nonce: String, ts: String, pow: String, leadingZeroBits: Int = 8) -> Bool {
        guard pow.count == 32, pow.unicodeScalars.allSatisfy({ isHexScalar($0) }) else { return false }
        let digest = sha256(Data(powMessage(nonce: nonce, ts: ts, pow: pow).utf8))
        return hasLeadingZeroBits(digest, bits: leadingZeroBits)
    }

    /// The preimage hashed for the proof of work.
    nonisolated static func powMessage(nonce: String, ts: String, pow: String) -> String {
        "\(ts)\n\(nonce)\n\(pow)"
    }

    // MARK: Ed25519

    /// Ed25519 signature of `message` as base64 (64-byte signature → 88 chars,
    /// the observed `x-client-sig` wire length).
    nonisolated static func sign(message: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        Data(try privateKey.signature(for: message)).base64EncodedString()
    }

    // MARK: - Private

    /// Leading zero bits the solver targets (protocol `powBits: 8`).
    private nonisolated static let leadingZeroBitBudget = 8

    private nonisolated static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private nonisolated static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
    }

    private nonisolated static func hasLeadingZeroBits(_ data: Data, bits: Int) -> Bool {
        var remaining = bits
        for byte in data {
            guard remaining > 0 else { return true }
            if remaining >= 8 {
                guard byte == 0 else { return false }
                remaining -= 8
            } else {
                return byte >> (8 - remaining) == 0
            }
        }
        return remaining == 0
    }
}
