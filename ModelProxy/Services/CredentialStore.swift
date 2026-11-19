import CryptoKit
import Foundation
import Security

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

    /// Base-aware remedy: the bare command for the shared default base;
    /// otherwise the CLI writes where ZGate reads via `ZCODE_DATA_BASE_DIR`
    /// (the CLI's own data-base env var — the same semantics `resolveBase`
    /// applies), so the remedy can always clear the alert.
    static func loginRemedy(forBase base: URL?) -> String {
        guard let base, base != defaultBase else { return loginRemedy }
        return "ZCODE_DATA_BASE_DIR=\(base.path) " + loginRemedy
    }

    /// The CLI's file-secret location: colocated with the store file (the
    /// CLI resolves it without any env vars). ZGate-created stores write
    /// their secret HERE so the CLI can read what ZGate sealed — the CLI
    /// never looks at `<base>/secret.txt`.
    static let colocatedSecretFileName = "credential-secret"

    static let accessTokenField = "oauth:zai:access_token"
    static let zcodeJwtTokenField = "zcodejwttoken"
    static let projectKeyLocationFieldPrefix = "project-key-location:v1:"
    static let activeProviderField = "oauth:active_provider"
    static let userInfoField = "oauth:zai:user_info"
    static let sessionRevisionField = "oauth:session_revision"

    /// The GUI/CLI shared store base (approved user decision 2026-11-18):
    /// `$HOME`, the zcode CLI's default `ZCODE_DATA_BASE_DIR`, so the
    /// shared store resolves to `~/.zcode/v2/credentials.json` — exactly
    /// where a normally-installed, logged-in CLI writes it (layout
    /// `<data-base>/.zcode/v2/…`). 2.8(7) and earlier pointed this at
    /// `~/.zcode` itself, resolving the nonexistent `~/.zcode/.zcode/v2`
    /// — the shared-store read never succeeded on any machine.
    nonisolated static var sharedBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
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

    private static let fingerprintLength = 24

    /// Envelope flavors the store can carry (the CLI's `enc:v2:` scheme).
    /// `env` seals under SHA256(secret-file bytes) with the secret file
    /// passed via `ZCODE_CREDENTIAL_SECRET_FILE` (ZGate's classic layout);
    /// `os` — the CLI's default `credential-source` — seals under the raw
    /// 32-byte Keychain secret. The flavor lives in the envelope prefix,
    /// so a store can mix them; each field decrypts with its own flavor's
    /// key.
    enum EnvelopeFlavor: String {
        case env = "enc:v2:env:"
        case os = "enc:v2:os:"
    }

    /// One candidate AES key for decrypting (and re-sealing) a store, with
    /// the flavor it serves. Key bytes only — never logged.
    struct StoreKey {
        let flavor: EnvelopeFlavor
        /// AES key bytes: SHA256(secret-file bytes) for `env`, the raw
        /// Keychain password bytes for `os`.
        let keyData: Data
        /// The `env` flavor's secret-file bytes (re-sealing needs them);
        /// nil for `os`.
        let secretData: Data?
    }

    /// SHA-256 hex of the store file's absolute path — the CLI's Keychain
    /// account string for the os-flavor secret (live-verified 2026-11-19:
    /// service "ZCode Credential Encryption", account = this digest).
    static func keychainAccount(forStoreAt url: URL) -> String {
        SHA256.hash(data: Data(url.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Field name → decrypted (or plaintext passthrough) value.
    private let values: [String: String]

    /// The key that decrypted the store's envelopes (nil for all-plaintext
    /// stores). `saveZaiLogin` re-seals with this exact key so the CLI
    /// remains a co-tenant of a store ZGate did not create.
    private(set) var sealingKey: StoreKey?

    // MARK: - Loading

    /// Loads and decrypts the store. Secret candidates, in resolution
    /// order: the CLI's colocated file secret
    /// `<store-dir>/credential-secret` (env), the ZGate/scratch
    /// `secretURL` (env), and the Keychain os secret (the CLI default).
    /// Each encrypted field decrypts with the candidate matching its
    /// flavor and fingerprint.
    init(storeURL: URL, secretURL: URL, keychain: any KeychainReading = LiveKeychain()) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw CredentialError.notFound(path: storeURL.path)
        }

        let storeData: Data
        do { storeData = try Data(contentsOf: storeURL) }
        catch { throw CredentialError.unreadable(path: storeURL.path) }

        let fields: [String: String]
        do { fields = try JSONDecoder().decode([String: String].self, from: storeData) }
        catch {
            throw CredentialError.malformedStore(
                path: storeURL.path, reason: "not a JSON object mapping field names to string values")
        }

        var candidates: [StoreKey] = []
        let colocatedSecretURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(Self.colocatedSecretFileName)
        for url in [colocatedSecretURL, secretURL] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let secret: Data
            do { secret = try Data(contentsOf: url) }
            catch { throw CredentialError.unreadable(path: url.path) }
            candidates.append(StoreKey(
                flavor: .env,
                keyData: Data(SHA256.hash(data: secret)),
                secretData: secret))
        }
        if let rawKey = try? keychain.osSecretKey(account: Self.keychainAccount(forStoreAt: storeURL)) {
            candidates.append(StoreKey(flavor: .os, keyData: rawKey, secretData: nil))
        }
        guard !candidates.isEmpty else {
            // Same contract as the pre-adoption loader: with no secret
            // from any source the store can never open — name the classic
            // secret path so the remedy points at a re-login.
            throw CredentialError.notFound(path: secretURL.path)
        }

        var decrypted: [String: String] = [:]
        var usedKey: StoreKey?
        // Sorted key order makes the first failure deterministic.
        for field in fields.keys.sorted() {
            let envelope = fields[field] ?? ""
            guard envelope.hasPrefix("enc:") else {
                decrypted[field] = envelope  // unencrypted value — the CLI store tolerates these
                continue
            }
            let flavor: EnvelopeFlavor?
            if envelope.hasPrefix(EnvelopeFlavor.env.rawValue) {
                flavor = .env
            } else if envelope.hasPrefix(EnvelopeFlavor.os.rawValue) {
                flavor = .os
            } else {
                flavor = nil
            }
            guard let flavor else {
                throw CredentialError.malformedValue(
                    field: field,
                    reason: "unsupported envelope (expected \(EnvelopeFlavor.env.rawValue)… or \(EnvelopeFlavor.os.rawValue)…)")
            }

            let sealed = try Self.parseEnvelope(envelope, flavor: flavor, field: field)
            guard let key = candidates.first(where: {
                $0.flavor == flavor && Self.fingerprint(ofKey: $0.keyData) == sealed.fingerprint
            }) else {
                throw CredentialError.fingerprintMismatch(field: field)
            }

            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: sealed.nonce),
                    ciphertext: sealed.ciphertext,
                    tag: sealed.authTag)
                plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key.keyData))
            } catch {
                throw CredentialError.decryptFailed(field: field)
            }
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw CredentialError.malformedValue(field: field, reason: "decrypted value is not valid UTF-8")
            }
            decrypted[field] = value
            usedKey = key
        }
        self.values = decrypted
        self.sealingKey = usedKey
    }

    /// Loads `<base>/.zcode/v2/credentials.json` (secret candidates:
    /// `<store-dir>/credential-secret`, `<base>/secret.txt`, Keychain).
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

    private static func parseEnvelope(
        _ envelope: String, flavor: EnvelopeFlavor, field: String
    ) throws -> SealedEnvelope {
        let rest = String(envelope.dropFirst(flavor.rawValue.count))
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
    /// The existing store is Keychain-sealed (os envelopes) and access to
    /// its Keychain secret was refused. The store is NOT quarantined —
    /// destroying a live CLI login over an access prompt is worse than
    /// aborting; allow access (or re-login the CLI) and retry.
    case keychainAccessDenied
    /// The Keychain is present but unusable right now (service down, or
    /// the item's password is not a parseable key). The store is NOT
    /// quarantined — the CLI login may be intact and the failure
    /// environmental; retry after the environment recovers.
    case keychainUnavailable
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

    /// Seals `value` under `key` exactly as the read path expects — the
    /// inverse of the decrypt above: AES-256-GCM, envelope
    /// `<flavor-prefix><24-hex fingerprint>:<iv>.<tag>.<ct>` with the
    /// triple in unpadded base64url. Fresh random nonce per value (the
    /// committed fixtures' deterministic IVs are test-only).
    static func sealEnvelope(value: String, key: StoreKey) throws -> String {
        let sealed = try AES.GCM.seal(
            Data(value.utf8), using: SymmetricKey(data: key.keyData))
        let fingerprint = Self.fingerprint(ofKey: key.keyData)
        return key.flavor.rawValue + fingerprint
            + ":\(Base64URL.encode(Data(sealed.nonce)))"
            + ".\(Base64URL.encode(Data(sealed.tag)))"
            + ".\(Base64URL.encode(sealed.ciphertext))"
    }

    /// Env-flavor seal under key = SHA256(secret bytes) — the classic
    /// secret-file form (write-path default, test fixtures).
    static func sealEnvelope(value: String, secretData: Data) throws -> String {
        try sealEnvelope(
            value: value,
            key: StoreKey(
                flavor: .env,
                keyData: Data(SHA256.hash(data: secretData)),
                secretData: secretData))
    }

    /// Writes the field set the CLI's `saveZaiLoginCredentials` writes on
    /// flow `ready` (§A.6 step 4): `oauth:active_provider`,
    /// `oauth:zai:access_token`, `zcodejwttoken`, `oauth:zai:user_info`,
    /// preserving existing `project-key-location:v1:*` entries verbatim
    /// and wiping other-provider fields. `oauth:session_revision` bumps
    /// with expected-revision CAS semantics — a stale expectation throws
    /// `revisionConflict` and leaves the store untouched.
    ///
    /// Adoption (2026-11-19): an existing store is first read through the
    /// full candidate ladder (colocated credential-secret, `<base>/secret.txt`,
    /// Keychain). A READABLE store — including a CLI login with os
    /// envelopes under the Keychain secret — is preserved in place and
    /// re-sealed with its own key/flavor, so the CLI stays a co-tenant.
    /// Only a store no secret from any source can open is quarantined
    /// aside as `credentials.json.unreadable-store` (replaced on each
    /// occurrence) and rewritten as a virgin store — and an os-sealed
    /// store whose Keychain access was REFUSED aborts with
    /// `keychainAccessDenied` instead of being destroyed.
    ///
    /// Files: `<base>/.zcode/v2/credentials.json` + `<base>/secret.txt`
    /// (a virgin store gets a freshly generated 32-byte secret). Writes
    /// are 0600 from the first byte and atomic (temp + rename, mirroring
    /// BizSessionCache.save). The returned `ZaiLoginSaveResult` flags the
    /// quarantine and whether the resulting store carries no location
    /// entry (the honest-gap warning fast-follow F3).
    @discardableResult
    static func saveZaiLogin(
        accessToken: String,
        zcodeJwtToken: String,
        userInfoJSON: String,
        base: URL,
        expectedRevision: Int64? = nil,
        keychain: any KeychainReading = LiveKeychain()
    ) throws -> ZaiLoginSaveResult {
        let fileManager = FileManager.default
        let storeURL = base.appendingPathComponent(".zcode/v2/credentials.json")
        let secretURL = base.appendingPathComponent("secret.txt")

        func readRawFields() throws -> [String: String] {
            guard fileManager.fileExists(atPath: storeURL.path) else { return [:] }
            let data = try Data(contentsOf: storeURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        }

        let storeExisted = fileManager.fileExists(atPath: storeURL.path)
        let secretExisted = fileManager.fileExists(atPath: secretURL.path)

        // Full read through the candidate ladder BEFORE any quarantine
        // decision: a CLI-written store (os envelopes + Keychain secret,
        // no secret file) is perfectly readable and must be preserved in
        // place, re-sealed with its own flavor.
        var readable: CredentialStore?
        var existing: [String: String] = [:]
        if storeExisted {
            existing = try readRawFields()
            readable = try? CredentialStore(storeURL: storeURL, secretURL: secretURL, keychain: keychain)
        }

        var quarantined = false
        if storeExisted, readable == nil {
            // An os-sealed store is unreadable only because its Keychain
            // secret is gone or was refused. A refusal must NOT destroy
            // the CLI's login — abort; only a missing secret (dead
            // envelopes, no source anywhere) justifies the quarantine.
            if existing.values.contains(where: { $0.hasPrefix(EnvelopeFlavor.os.rawValue) }) {
                do {
                    _ = try keychain.osSecretKey(account: Self.keychainAccount(forStoreAt: storeURL))
                    // A key exists but did not decrypt the envelopes —
                    // treat as dead (fingerprint mismatch), quarantine.
                } catch KeychainSecretFailure.itemNotFound {
                    // Provably absent: the envelopes are cryptographically
                    // dead — quarantine below is the only path.
                } catch KeychainSecretFailure.accessDenied {
                    throw CredentialWriteError.keychainAccessDenied
                } catch {
                    // Unavailable (keychain service down, unparseable
                    // password): environmental, possibly transient — never
                    // destroy a live CLI login over it.
                    throw CredentialWriteError.keychainUnavailable
                }
            }
            let quarantineURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(Self.unreadableStoreQuarantineName)
            if rename(storeURL.path, quarantineURL.path) != 0 {
                let errorCode = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey:
                        "could not quarantine unreadable store: \(String(cString: strerror(errorCode)))"])
            }
            quarantined = true
            existing = [:]
        }

        // Sealing key: the readable store's own key (os → the same
        // Keychain key, env → the same secret bytes); otherwise the env
        // flavor with the existing secret file or a fresh secret.
        var freshSecret: Data?
        let sealingKey: StoreKey
        if let readerKey = readable?.sealingKey {
            sealingKey = readerKey
        } else if secretExisted, let secretData = try? Data(contentsOf: secretURL) {
            sealingKey = StoreKey(
                flavor: .env,
                keyData: Data(SHA256.hash(data: secretData)),
                secretData: secretData)
        } else {
            // Virgin (or secret-less) store: mint the CLI's own file-secret
            // convention so the CLI stays a co-tenant of what ZGate seals —
            // the colocated credential-secret holding the secret as an
            // ASCII base64url STRING (the CLI hashes the file's UTF-8
            // bytes; raw random bytes would be invalid UTF-8, and the CLI
            // never looks at <base>/secret.txt).
            let secretData = Data(Base64URL.encode(Self.generateSecret()).utf8)
            freshSecret = secretData
            sealingKey = StoreKey(
                flavor: .env,
                keyData: Data(SHA256.hash(data: secretData)),
                secretData: secretData)
        }

        // CAS: the readable store's revision (a virgin/quarantined path
        // has none → 0).
        let foundRevision: Int64 = {
            guard let readable else { return 0 }
            guard let raw = try? readable.value(for: sessionRevisionField) else { return 0 }
            return Int64(raw) ?? 0
        }()
        let expected = expectedRevision ?? foundRevision
        guard expected == foundRevision else {
            throw CredentialWriteError.revisionConflict(expected: expected, found: foundRevision)
        }

        // Assemble: preserved location entries verbatim, the zai login
        // set sealed fresh under the sealing key, revision bumped.
        var fields = existing.filter { $0.key.hasPrefix(projectKeyLocationFieldPrefix) }
        fields[activeProviderField] = try sealEnvelope(value: "zai", key: sealingKey)
        fields[accessTokenField] = try sealEnvelope(value: accessToken, key: sealingKey)
        fields[zcodeJwtTokenField] = try sealEnvelope(value: zcodeJwtToken, key: sealingKey)
        fields[userInfoField] = try sealEnvelope(value: userInfoJSON, key: sealingKey)
        fields[sessionRevisionField] = try sealEnvelope(
            value: String(foundRevision + 1), key: sealingKey)

        // Narrow the CAS window: re-read and re-verify right before write.
        // A reread that FAILS to open is not a revision-0 store — when the
        // first read succeeded at a nonzero revision the likely cause is a
        // later Keychain refusal; abort with the typed error instead of a
        // false conflict (or an unverified blind write).
        if storeExisted, !quarantined {
            let reread = try readRawFields()
            if !reread.isEmpty {
                if let rereadStore = try? CredentialStore(
                    storeURL: storeURL, secretURL: secretURL, keychain: keychain)
                {
                    let rereadRevision: Int64 = {
                        guard let raw = try? rereadStore.value(for: sessionRevisionField)
                        else { return 0 }
                        return Int64(raw) ?? 0
                    }()
                    guard rereadRevision == foundRevision else {
                        throw CredentialWriteError.revisionConflict(
                            expected: foundRevision, found: rereadRevision)
                    }
                } else if foundRevision > 0,
                    reread.values.contains(where: {
                        $0.hasPrefix(EnvelopeFlavor.os.rawValue)
                    })
                {
                    throw CredentialWriteError.keychainAccessDenied
                }
            }
        }

        try Self.writeAtomically0600(
            try JSONEncoder().encode(fields), to: storeURL)
        // An os-sealed store never touches a secret FILE — its key lives
        // in the Keychain already; writing one would shadow the real
        // source. A freshly generated env secret goes to the CLI's
        // colocated location (see the virgin-path comment above).
        if let freshSecret {
            try Self.writeAtomically0600(
                freshSecret,
                to: storeURL.deletingLastPathComponent()
                    .appendingPathComponent(Self.colocatedSecretFileName))
        }
        return ZaiLoginSaveResult(
            storeLacksProjectLocation: !fields.keys.contains {
                $0.hasPrefix(projectKeyLocationFieldPrefix)
            },
            quarantinedUnreadableStore: quarantined)
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

// MARK: - Keychain os-secret seam (CLI co-tenancy)

/// Typed failures of `KeychainReading` (file scope — Swift forbids
/// nested types in protocols).
enum KeychainSecretFailure: Error, Equatable {
    /// No item for the account — the CLI never stored (or removed) it.
    case itemNotFound
    /// The item exists but access was refused (ACL / user deny).
    case accessDenied
    /// The item exists but its password is not a usable 32-byte key.
    case unavailable
}

/// Reads the CLI's Keychain-held os-flavor secret: the zcode CLI stores
/// the 32-byte AES key as a base64url password under service
/// "ZCode Credential Encryption", account = SHA-256 hex of the store
/// file's absolute path. Injectable so store tests never touch the real
/// Keychain; the live reader is inert inside the isolated test host.
protocol KeychainReading: Sendable {
    /// Raw key bytes for `account`.
    func osSecretKey(account: String) throws -> Data
}

struct LiveKeychain: KeychainReading {
    static let service = "ZCode Credential Encryption"

    /// Process-wide probe cache: the store loader runs on every status
    /// tick (~20 s) and several times per chain build, so an
    /// ACL-protected item would otherwise prompt on EVERY probe. Positive
    /// results cache for the process lifetime; denials cache per account
    /// so a refusal can never become a prompt loop. Keyed by account (=
    /// the store-path digest). Key bytes only — never logged.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedKeys: [String: Data] = [:]
    private nonisolated(unsafe) static var deniedAccounts: Set<String> = []

    func osSecretKey(account: String) throws -> Data {
        // Never probe the login Keychain from the isolated test host.
        if AppPaths.isolatedBase != nil { throw KeychainSecretFailure.itemNotFound }
        Self.cacheLock.lock()
        if let cached = Self.cachedKeys[account] {
            Self.cacheLock.unlock()
            return cached
        }
        if Self.deniedAccounts.contains(account) {
            Self.cacheLock.unlock()
            throw KeychainSecretFailure.accessDenied
        }
        Self.cacheLock.unlock()

        let key = try tryProbe(account: account)

        Self.cacheLock.lock()
        Self.cachedKeys[account] = key
        Self.cacheLock.unlock()
        return key
    }

    private func tryProbe(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let denied: Bool
        switch status {
        case errSecSuccess:
            denied = false
        case errSecItemNotFound:
            throw KeychainSecretFailure.itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            denied = true
        default:
            throw KeychainSecretFailure.unavailable
        }
        if denied {
            Self.cacheLock.lock()
            Self.deniedAccounts.insert(account)
            Self.cacheLock.unlock()
            throw KeychainSecretFailure.accessDenied
        }
        guard let data = item as? Data else { throw KeychainSecretFailure.unavailable }
        // Keychain passwords are the password string's UTF-8 bytes; the
        // CLI stores a 43-char base64url string. Tolerate a raw 32-byte
        // item too.
        if data.count == 32 { return data }
        if let password = String(data: data, encoding: .utf8),
            let key = Base64URL.decode(password), key.count == 32
        { return key }
        throw KeychainSecretFailure.unavailable
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
