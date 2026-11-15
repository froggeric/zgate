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

    /// Message signed by the handshake request's `sig` field
    /// (`ts` is the 13-char ms-epoch string).
    nonisolated static func handshakeSigMessage(apiKeyId: String, ts: String, nonce: String) -> String {
        "get_sign_key\n\(apiKeyId)\n\(ts)\n\(nonce)"
    }

    /// Message signed by the relay request's `X-Client-Sig` header.
    nonisolated static func requestSigMessage(apiKeyId: String, ts: String, version: String, sessionId: String, nonce: String) -> String {
        "\(apiKeyId)\n\(ts)\n\(version)\n\(sessionId)\n\(nonce)"
    }

    // MARK: HMAC

    /// HMAC-SHA256 of `message` (UTF-8) under `key`, raw 32 bytes.
    nonisolated static func hmac(message: String, key: Data) -> Data {
        hmac(Data(message.utf8), key: key)
    }

    /// HMAC-SHA256 as lowercase hex (64 chars).
    nonisolated static func hmacHex(message: String, key: Data) -> String {
        hex(hmac(message: message, key: key))
    }

    /// HMAC-SHA256 as base64 (44 chars) — the handshake `sig` wire form
    /// (live capture 2026-11-15: handshake body carries `sig` as a 44-char string).
    nonisolated static func hmacBase64(message: String, key: Data) -> String {
        hmac(message: message, key: key).base64EncodedString()
    }

    // MARK: Proof of work

    /// A solved proof of work.
    nonisolated struct ProofOfWork: Equatable {
        /// The challenge: first 32 hex chars of SHA-256("apiKeyId\nappId\nsessionId\nts").
        let n: String
        /// The proof (sent as the relay's `x-client-pow`): 24-hex random prefix
        /// + 8-hex counter suffix; SHA-256("n\nvalue") has ≥ 8 leading zero bits.
        let value: String
    }

    /// Solves the relay's proof of work (bundle-derived, live-verified 2026-11-15).
    ///
    /// `n` comes from the request identity — `sha256("apiKeyId\nappId\nsessionId\nts").hex[0:32]` —
    /// and the search walks counter values `i`, forming `value = <24-hex prefix><i as 8-hex>`
    /// and accepting the first whose `sha256("n\nvalue")` has `leadingZeroBitBudget`
    /// leading zero bits (first byte 0x00 at the protocol's 8 bits; expected ~2^8
    /// attempts, the default bound allows 32× headroom). The prefix is normally
    /// 12 random bytes; pass a fixed one to make the search deterministic (tests do).
    /// Returns nil if no proof is found within `maxAttempts`.
    nonisolated static func pow(
        apiKeyId: String,
        appId: String,
        sessionId: String,
        ts: String,
        prefix: String? = nil,
        maxAttempts: Int = 1 << 13
    ) -> ProofOfWork? {
        let n = powN(apiKeyId: apiKeyId, appId: appId, sessionId: sessionId, ts: ts)
        let base = prefix ?? randomHexPrefix()
        for attempt in 0 ..< UInt32(clamping: max(0, maxAttempts)) {
            let value = base + String(format: "%08x", attempt)
            if hasLeadingZeroBits(sha256(Data("\(n)\n\(value)".utf8)), bits: leadingZeroBitBudget) {
                return ProofOfWork(n: n, value: value)
            }
        }
        return nil
    }

    /// Verifies a 32-hex `value` against the same identity inputs `pow(...)` takes.
    /// Hex letters are case-insensitive; the preimage uses the lowercase form.
    nonisolated static func verifyPow(
        apiKeyId: String,
        appId: String,
        sessionId: String,
        ts: String,
        pow value: String,
        leadingZeroBits: Int = 8
    ) -> Bool {
        let normalized = value.lowercased()
        guard normalized.count == 32, normalized.unicodeScalars.allSatisfy({ isHexScalar($0) }) else { return false }
        let n = powN(apiKeyId: apiKeyId, appId: appId, sessionId: sessionId, ts: ts)
        return hasLeadingZeroBits(sha256(Data("\(n)\n\(normalized)".utf8)), bits: leadingZeroBits)
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

    /// The PoW challenge `n`: first 32 hex chars of SHA-256 over the identity fields.
    private nonisolated static func powN(apiKeyId: String, appId: String, sessionId: String, ts: String) -> String {
        String(hex(sha256(Data("\(apiKeyId)\n\(appId)\n\(sessionId)\n\(ts)".utf8))).prefix(32))
    }

    /// 24 lowercase hex chars of randomness (CryptoKit's RNG, 32 bytes kept as 24).
    private nonisolated static func randomHexPrefix() -> String {
        String(SymmetricKey(size: .bits256).withUnsafeBytes { hex(Data($0)) }.prefix(24))
    }

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
        ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
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
