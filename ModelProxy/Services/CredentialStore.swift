import CryptoKit
import Foundation

/// Typed failures for loading and decrypting the zcode scratch credential store.
/// Associated values carry file paths, store field names, and structural reasons
/// only — never credential bytes or decrypted values.
enum CredentialError: Error, Equatable, LocalizedError {
    /// A required file (store or secret) does not exist at `path`.
    case notFound(path: String)
    /// A file exists but could not be read (e.g. permissions).
    case unreadable(path: String)
    /// The store file is not a JSON object of string values.
    case malformedStore(path: String, reason: String)
    /// The envelope's key fingerprint does not match SHA256(secret file bytes) —
    /// the secret file belongs to a different store.
    case fingerprintMismatch(field: String)
    /// AES-256-GCM authenticated decryption failed (corrupted or tampered value).
    case decryptFailed(field: String)
    /// The envelope is structurally invalid (bad prefix, fingerprint, base64url
    /// part, or part lengths) or the plaintext is not UTF-8.
    case malformedValue(field: String, reason: String)
    /// The requested store key is not present.
    case missingField(name: String)

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Credential file not found: \(path). Create it by logging in:\n\(CredentialStore.loginRemedy)"
        case let .unreadable(path):
            "Credential file could not be read: \(path)."
        case let .malformedStore(path, reason):
            "Credential store at \(path) is malformed: \(reason)."
        case let .fingerprintMismatch(field):
            "Credential store field \"\(field)\" was encrypted with a different "
                + "secret file. Re-login with the matching secret is required:\n"
                + CredentialStore.loginRemedy
        case let .decryptFailed(field):
            "Credential store field \"\(field)\" failed authenticated decryption "
                + "(data is corrupted or was tampered with)."
        case let .malformedValue(field, reason):
            "Credential store field \"\(field)\" is malformed: \(reason)."
        case let .missingField(name):
            "Credential store has no field \"\(name)\"."
        }
    }
}

/// Decoded `project-key-location:v1:<percent-encoded>` store entry: the
/// persisted org/project location cache for the api_keys mint flow. Plaintext
/// shape (docs/signing-notes.md): `["<origin>", "<family>", "<account>", null, <generation>, "<label>"]`.
struct ProjectKeyLocation: Equatable {
    /// API origin, e.g. `"https://api.z.ai"`.
    let origin: String
    /// Account family, e.g. `"zai"`.
    let family: String
    /// Account UUID.
    let account: String
    /// Full decrypted JSON array, for fields later tasks may need.
    let rawJSON: String
}

/// Loads the zcode scratch-home credential store, verifies each value's key
/// fingerprint, decrypts the AES-256-GCM envelopes, and exposes typed tokens.
///
/// Store layout (`ZCODE_DATA_BASE_DIR`, see docs/signing-notes.md):
/// `<scratch-home>/.zcode/v2/credentials.json` + `<scratch-home>/secret.txt`.
/// Envelope format `enc:v2:env:<24-hex fingerprint>:<iv>.<tag>.<ct>` with the
/// triple in unpadded base64url (RFC 4648 §5); key = SHA256(secret file bytes);
/// fingerprint = first 24 hex chars of SHA256(key), verified before opening.
///
/// This type never logs: no credential byte is ever converted into a logged
/// string. Errors carry paths and field names only.
struct CredentialStore {

    /// Interactive re-login command that (re)creates the scratch store and
    /// secret file (mirrors docs/signing-notes.md).
    static let loginRemedy =
        "ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt "
        + "node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai"

    static let accessTokenField = "oauth:zai:access_token"
    static let zcodeJwtTokenField = "zcodejwttoken"
    static let projectKeyLocationFieldPrefix = "project-key-location:v1:"

    /// Default scratch home used by the zcode capture flow.
    static var defaultScratchHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode-scratch-v3")
    }

    private static let envelopePrefix = "enc:v2:env:"
    private static let fingerprintLength = 24

    /// Field name → decrypted (or plaintext passthrough) value.
    private let values: [String: String]

    // MARK: - Loading

    init(storeURL: URL, secretURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw CredentialError.notFound(path: storeURL.path)
        }
        guard fileManager.fileExists(atPath: secretURL.path) else {
            throw CredentialError.notFound(path: secretURL.path)
        }

        let storeData: Data
        do { storeData = try Data(contentsOf: storeURL) }
        catch { throw CredentialError.unreadable(path: storeURL.path) }
        let secretData: Data
        do { secretData = try Data(contentsOf: secretURL) }
        catch { throw CredentialError.unreadable(path: secretURL.path) }

        let fields: [String: String]
        do { fields = try JSONDecoder().decode([String: String].self, from: storeData) }
        catch {
            throw CredentialError.malformedStore(
                path: storeURL.path, reason: "not a JSON object mapping field names to string values")
        }

        let keyData = Data(SHA256.hash(data: secretData))
        let key = SymmetricKey(data: keyData)
        let fingerprint = Self.fingerprint(ofKey: keyData)

        var decrypted: [String: String] = [:]
        // Sorted key order makes the first failure deterministic.
        for field in fields.keys.sorted() {
            let envelope = fields[field] ?? ""
            if !envelope.hasPrefix(Self.envelopePrefix) {
                guard envelope.hasPrefix("enc:") else {
                    decrypted[field] = envelope  // unencrypted value — the CLI store tolerates these
                    continue
                }
                throw CredentialError.malformedValue(
                    field: field, reason: "unsupported envelope (expected \(Self.envelopePrefix)…)")
            }

            let sealed = try Self.parseEnvelope(envelope, field: field)
            guard sealed.fingerprint == fingerprint else {
                throw CredentialError.fingerprintMismatch(field: field)
            }

            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: sealed.nonce),
                    ciphertext: sealed.ciphertext,
                    tag: sealed.authTag)
                plaintext = try AES.GCM.open(box, using: key)
            } catch {
                throw CredentialError.decryptFailed(field: field)
            }
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw CredentialError.malformedValue(field: field, reason: "decrypted value is not valid UTF-8")
            }
            decrypted[field] = value
        }
        self.values = decrypted
    }

    /// Loads `<scratch-home>/.zcode/v2/credentials.json` + `<scratch-home>/secret.txt`.
    init(scratchHome: URL) throws {
        try self.init(
            storeURL: scratchHome.appendingPathComponent(".zcode/v2/credentials.json"),
            secretURL: scratchHome.appendingPathComponent("secret.txt"))
    }

    /// Loads from `CredentialStore.defaultScratchHome`.
    static func loadDefault() throws -> CredentialStore {
        try CredentialStore(scratchHome: defaultScratchHome)
    }

    // MARK: - Typed accessors

    /// Raw decrypted value for a store field.
    func value(for field: String) throws -> String {
        guard let value = values[field] else { throw CredentialError.missingField(name: field) }
        return value
    }

    /// `oauth:zai:access_token` — the 1-hour OAuth access JWT used for `z/login`.
    func accessToken() throws -> String {
        try value(for: Self.accessTokenField)
    }

    /// `zcodejwttoken` — the long-lived identity JWT (no `exp` claim).
    func zcodeJwtToken() throws -> String {
        try value(for: Self.zcodeJwtTokenField)
    }

    /// `exp` claim of the access token, or nil when the token carries none.
    func accessTokenExpiry() throws -> Date? {
        try Self.jwtExpiry(of: try accessToken(), field: Self.accessTokenField)
    }

    /// The persisted project-key location entry, or nil when the store has none.
    func projectKeyLocation() throws -> ProjectKeyLocation? {
        guard let field = values.keys
            .filter({ $0.hasPrefix(Self.projectKeyLocationFieldPrefix) })
            .sorted().first,
            let raw = values[field]
        else { return nil }
        return try Self.parseProjectKeyLocation(raw, field: field)
    }

    // MARK: - JWT parsing

    /// Extracts the `exp` claim from a compact JWT's payload segment.
    /// Handles unpadded base64url; values above 1e12 are treated as millisecond
    /// epochs (some z.ai tokens use ms), otherwise as seconds.
    static func jwtExpiry(of token: String, field: String) throws -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3 else {
            throw CredentialError.malformedValue(field: field, reason: "not a three-part JWT")
        }
        guard let payload = Base64URL.decode(segments[1]) else {
            throw CredentialError.malformedValue(field: field, reason: "payload segment is not valid base64url")
        }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: payload) }
        catch { throw CredentialError.malformedValue(field: field, reason: "payload segment is not JSON") }
        guard let claims = json as? [String: Any] else {
            throw CredentialError.malformedValue(field: field, reason: "payload is not a JSON object")
        }
        guard let exp = claims["exp"] as? Double else { return nil }
        let seconds = exp > 1e12 ? exp / 1000 : exp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseProjectKeyLocation(_ raw: String, field: String) throws -> ProjectKeyLocation {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) }
        catch { throw CredentialError.malformedValue(field: field, reason: "location value is not JSON") }
        guard let elements = json as? [Any], elements.count >= 3,
            let origin = elements[0] as? String,
            let family = elements[1] as? String,
            let account = elements[2] as? String
        else {
            throw CredentialError.malformedValue(
                field: field, reason: "location value is not a [origin, family, account, …] JSON array")
        }
        return ProjectKeyLocation(origin: origin, family: family, account: account, rawJSON: raw)
    }

    // MARK: - Envelope parsing

    private struct SealedEnvelope {
        let fingerprint: String
        let nonce: Data
        let authTag: Data
        let ciphertext: Data
    }

    private static func parseEnvelope(_ envelope: String, field: String) throws -> SealedEnvelope {
        let rest = String(envelope.dropFirst(envelopePrefix.count))
        guard let colon = rest.firstIndex(of: ":") else {
            throw CredentialError.malformedValue(field: field, reason: "missing key fingerprint")
        }
        let fileFingerprint = String(rest[..<colon])
        guard fileFingerprint.count == fingerprintLength,
            fileFingerprint.allSatisfy({ $0.isHexDigit })
        else {
            throw CredentialError.malformedValue(
                field: field, reason: "key fingerprint is not \(fingerprintLength) hex characters")
        }
        let blob = String(rest[rest.index(after: colon)...])
        let parts = blob.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw CredentialError.malformedValue(
                field: field, reason: "expected <iv>.<tag>.<ciphertext>, found \(parts.count) parts")
        }
        guard let nonce = Base64URL.decode(parts[0]),
            let authTag = Base64URL.decode(parts[1]),
            let ciphertext = Base64URL.decode(parts[2])
        else {
            throw CredentialError.malformedValue(field: field, reason: "iv/tag/ciphertext is not valid base64url")
        }
        guard nonce.count == 12 else {
            throw CredentialError.malformedValue(
                field: field, reason: "nonce is \(nonce.count) bytes, expected 12")
        }
        guard authTag.count == 16 else {
            throw CredentialError.malformedValue(
                field: field, reason: "auth tag is \(authTag.count) bytes, expected 16")
        }
        return SealedEnvelope(
            fingerprint: fileFingerprint.lowercased(),
            nonce: nonce,
            authTag: authTag,
            ciphertext: ciphertext)
    }

    /// First 24 hex chars of SHA256(key) — the value each envelope carries.
    private static func fingerprint(ofKey keyData: Data) -> String {
        SHA256.hash(data: keyData)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(fingerprintLength)
            .description
    }
}

/// RFC 4648 §5 base64url codecs (url-safe alphabet, unpadded on the wire).
/// Padded input is tolerated when decoding.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        String(data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
        while base64.hasSuffix("=") { base64.removeLast() }
        guard base64.allSatisfy(Self.isBase64URLCharacter) else { return nil }
        base64 = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    nonisolated private static func isBase64URLCharacter(_ character: Character) -> Bool {
        ("A"..."Z").contains(character)
            || ("a"..."z").contains(character)
            || ("0"..."9").contains(character)
            || character == "-" || character == "_"
    }
}
