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

/// Decoded `project-key-location:v1:*` store entry: the persisted
/// org/project/apiKeyId location the api_keys mint call targets.
///
/// Live-verified shape (2026-11-15): the percent-encoded identity array
/// lives in the field NAME and is ignored here; the field's VALUE is the
/// JSON object `{"organizationId", "projectId", "apiKeyId"}`.
struct ProjectKeyLocation: Equatable {
    let organizationId: String
    let projectId: String
    let apiKeyId: String
    /// Full decrypted JSON object, for fields later tasks may need.
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

    /// Interactive re-login command that (re)creates the store and secret
    /// file in the shared default base (`$HOME/.zcode` — the CLI's own
    /// default, no env vars needed since the 2026-11-18 shared-store
    /// decision). Transitional: the in-app login client replaces it.
    static let loginRemedy =
        "node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai"

    static let accessTokenField = "oauth:zai:access_token"
    static let zcodeJwtTokenField = "zcodejwttoken"
    static let projectKeyLocationFieldPrefix = "project-key-location:v1:"
    static let activeProviderField = "oauth:active_provider"
    static let userInfoField = "oauth:zai:user_info"
    static let sessionRevisionField = "oauth:session_revision"

    /// The GUI/CLI shared store base (approved user decision 2026-11-18):
    /// the default `$HOME/.zcode` the zcode CLI and GUI both use, so a
    /// login in either is immediately visible to ZGate.
    nonisolated static var sharedBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode")
    }

    /// Legacy scratch home from the capture-time remedy (selectable via the
    /// persisted `credentialStoreBase` setting for installs that still
    /// ride it).
    nonisolated static var legacyScratchHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode-scratch-v3")
    }

    /// Data-base directory the default store resolves under (layout
    /// `<base>/.zcode/v2/credentials.json` + `<base>/secret.txt`; for the
    /// shared default the effective path is `$HOME/.zcode/v2/…`). An
    /// isolated test host redirects to its per-run temp base so suite runs
    /// never touch the live home store.
    nonisolated static var defaultBase: URL {
        AppPaths.isolatedBase ?? sharedBase
    }

    /// Maps the persisted `credentialStoreBase` setting to a store base:
    /// nil/empty = shared default (isolation-aware), otherwise the
    /// tilde-expanded absolute path string.
    nonisolated static func resolveBase(_ setting: String?) -> URL {
        guard let setting, !setting.isEmpty else { return defaultBase }
        return URL(
            fileURLWithPath: (setting as NSString).expandingTildeInPath,
            isDirectory: true)
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

    /// Loads `<base>/.zcode/v2/credentials.json` + `<base>/secret.txt`.
    init(base: URL) throws {
        try self.init(
            storeURL: base.appendingPathComponent(".zcode/v2/credentials.json"),
            secretURL: base.appendingPathComponent("secret.txt"))
    }

    /// Loads from `CredentialStore.defaultBase`, or an explicit base.
    static func loadDefault(base: URL? = nil) throws -> CredentialStore {
        try CredentialStore(base: base ?? defaultBase)
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
        guard let object = json as? [String: Any],
            let organizationId = object["organizationId"] as? String,
            let projectId = object["projectId"] as? String,
            let apiKeyId = object["apiKeyId"] as? String
        else {
            throw CredentialError.malformedValue(
                field: field,
                reason: "location value is not a {organizationId, projectId, apiKeyId} JSON object")
        }
        return ProjectKeyLocation(
            organizationId: organizationId, projectId: projectId, apiKeyId: apiKeyId, rawJSON: raw)
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

// MARK: - Envelope write path (item 4: in-app login)

/// Failures of the store write path. Carries revisions and field names
/// only — never credential bytes.
enum CredentialWriteError: Error, Equatable {
    /// `oauth:session_revision` changed between read and write — a
    /// concurrent writer committed first (expected-revision CAS).
    case revisionConflict(expected: Int64, found: Int64)
}

/// Outcome of `saveZaiLogin` — typed flags only, never credential bytes.
struct ZaiLoginSaveResult: Equatable {
    /// The written store carries no `project-key-location:v1:*` entry:
    /// identity persists, but the signing chain cannot mint a plan token
    /// until a location exists (one GUI/CLI login populates it).
    var storeLacksProjectLocation: Bool
    /// The previous store file existed without its secret — permanently
    /// unreadable — and was quarantined aside before a clean rewrite.
    var quarantinedUnreadableStore: Bool
}

extension CredentialStore {

    /// Seals `value` exactly as the read path expects — the inverse of the
    /// decrypt above: AES-256-GCM under key = SHA256(secret bytes),
    /// envelope `enc:v2:env:<24-hex fingerprint>:<iv>.<tag>.<ct>` with the
    /// triple in unpadded base64url. Fresh random nonce per value (the
    /// committed fixtures' deterministic IVs are test-only).
    static func sealEnvelope(value: String, secretData: Data) throws -> String {
        let keyData = Data(SHA256.hash(data: secretData))
        let sealed = try AES.GCM.seal(
            Data(value.utf8), using: SymmetricKey(data: keyData))
        let fingerprint = Self.fingerprint(ofKey: keyData)
        return "\(envelopePrefix)\(fingerprint)"
            + ":\(Base64URL.encode(Data(sealed.nonce)))"
            + ".\(Base64URL.encode(Data(sealed.tag)))"
            + ".\(Base64URL.encode(sealed.ciphertext))"
    }

    /// Writes the field set the CLI's `saveZaiLoginCredentials` writes on
    /// flow `ready` (§A.6 step 4): `oauth:active_provider`,
    /// `oauth:zai:access_token`, `zcodejwttoken`, `oauth:zai:user_info`,
    /// preserving existing `project-key-location:v1:*` entries verbatim
    /// (they stay sealed under the same secret) and wiping other-provider
    /// fields. `oauth:session_revision` bumps with expected-revision CAS
    /// semantics — a stale expectation throws `revisionConflict` and
    /// leaves the store untouched.
    ///
    /// Files: `<base>/.zcode/v2/credentials.json` + `<base>/secret.txt`.
    /// A store that does not exist yet gets a freshly generated 32-byte
    /// secret; an existing secret is reused (and must agree with the
    /// existing envelopes — a mismatch surfaces as the read path's
    /// `fingerprintMismatch`, never a blind overwrite). A store whose
    /// secret file is MISSING is permanently unreadable (its envelopes
    /// were sealed under a lost key): the write quarantines that file
    /// aside as `credentials.json.unreadable-store` (replaced on each
    /// occurrence) and writes a fresh virgin store instead of preserving
    /// dead entries. Writes are 0600 from the first byte and atomic
    /// (temp + rename, mirroring BizSessionCache.save). The returned
    /// `ZaiLoginSaveResult` flags the quarantine and whether the
    /// resulting store carries no location entry (the honest-gap warning
    /// fast-follow F3).
    @discardableResult
    static func saveZaiLogin(
        accessToken: String,
        zcodeJwtToken: String,
        userInfoJSON: String,
        base: URL,
        expectedRevision: Int64? = nil
    ) throws -> ZaiLoginSaveResult {
        let fileManager = FileManager.default
        let storeURL = base.appendingPathComponent(".zcode/v2/credentials.json")
        let secretURL = base.appendingPathComponent("secret.txt")

        // Poisoned precondition (review F3): the store exists but its
        // secret does not. The stored envelopes were sealed under the old
        // secret's key, so they are cryptographically dead — nothing can
        // be preserved and there is no migration path. Quarantine the
        // unreadable file aside (deterministic name, replaced on a later
        // occurrence — a user who recovers the old secret can restore)
        // and continue as a virgin store. Without this, the CAS decrypt
        // below throws notFound(secret) forever and wedges every login.
        let storeExisted = fileManager.fileExists(atPath: storeURL.path)
        let secretExisted = fileManager.fileExists(atPath: secretURL.path)
        if storeExisted && !secretExisted {
            let quarantineURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(Self.unreadableStoreQuarantineName)
            if rename(storeURL.path, quarantineURL.path) != 0 {
                let errorCode = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey:
                        "could not quarantine unreadable store: \(String(cString: strerror(errorCode)))"])
            }
        }

        // Secret: reuse the existing file, or generate one for a new store.
        let secretData: Data
        if secretExisted {
            secretData = try Data(contentsOf: secretURL)
        } else {
            secretData = Self.generateSecret()
        }

        func readRawFields() throws -> [String: String] {
            guard fileManager.fileExists(atPath: storeURL.path) else { return [:] }
            let data = try Data(contentsOf: storeURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        }

        // CAS: decrypt the existing store to read the current revision —
        // this also verifies the secret agrees with the envelopes.
        let existing = try readRawFields()
        let foundRevision: Int64 = try {
            guard !existing.isEmpty else { return 0 }
            let store = try CredentialStore(storeURL: storeURL, secretURL: secretURL)
            guard let raw = try? store.value(for: sessionRevisionField) else { return 0 }
            return Int64(raw) ?? 0
        }()
        let expected = expectedRevision ?? foundRevision
        guard expected == foundRevision else {
            throw CredentialWriteError.revisionConflict(expected: expected, found: foundRevision)
        }

        // Assemble: preserved location entries verbatim, the zai login
        // set sealed fresh, revision bumped.
        var fields = existing.filter { $0.key.hasPrefix(projectKeyLocationFieldPrefix) }
        fields[activeProviderField] = try sealEnvelope(value: "zai", secretData: secretData)
        fields[accessTokenField] = try sealEnvelope(value: accessToken, secretData: secretData)
        fields[zcodeJwtTokenField] = try sealEnvelope(value: zcodeJwtToken, secretData: secretData)
        fields[userInfoField] = try sealEnvelope(value: userInfoJSON, secretData: secretData)
        fields[sessionRevisionField] = try sealEnvelope(
            value: String(foundRevision + 1), secretData: secretData)

        // Narrow the CAS window: re-read and re-verify right before write.
        let reread = try readRawFields()
        if !reread.isEmpty {
            let rereadRevision: Int64 = try {
                let store = try CredentialStore(storeURL: storeURL, secretURL: secretURL)
                guard let raw = try? store.value(for: sessionRevisionField) else { return 0 }
                return Int64(raw) ?? 0
            }()
            guard rereadRevision == foundRevision else {
                throw CredentialWriteError.revisionConflict(
                    expected: foundRevision, found: rereadRevision)
            }
        }

        try Self.writeAtomically0600(
            try JSONEncoder().encode(fields), to: storeURL)
        if !secretExisted {
            try Self.writeAtomically0600(secretData, to: secretURL)
        }
        return ZaiLoginSaveResult(
            storeLacksProjectLocation: !fields.keys.contains {
                $0.hasPrefix(projectKeyLocationFieldPrefix)
            },
            quarantinedUnreadableStore: storeExisted && !secretExisted)
    }

    /// Quarantine name for a store written aside because its secret file
    /// is gone (the envelopes are undecryptable). Deterministic so a later
    /// occurrence replaces the earlier copy instead of accumulating files.
    static let unreadableStoreQuarantineName = "credentials.json.unreadable-store"

    /// 32 random bytes for a new store's secret file (SystemRandomNumberGenerator).
    private static func generateSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Writes `data` to `url` with owner-only permissions (0600) from its
    /// first byte and atomically (temp file + rename — rename(2) replaces
    /// atomically, same pattern as BizSessionCache.save).
    private static func writeAtomically0600(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path, contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw NSError(
                domain: "CredentialStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "could not create temporary store file at \(temporaryURL.path)"])
        }
        if rename(temporaryURL.path, url.path) != 0 {
            let errorCode = errno
            let reason = String(cString: strerror(errorCode))
            try? fileManager.removeItem(at: temporaryURL)
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "could not replace store file: \(reason)"])
        }
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
