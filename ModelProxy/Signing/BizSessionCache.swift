import Foundation

/// The org/project/apiKeyId triple the mint call targets.
///
/// Shape matches the credential store's `project-key-location:v1:*` **value**
/// (live-verified 2026-11-15: `{"organizationId","projectId","apiKeyId"}`) and
/// the persisted biz-session cache — deliberately wire-compatible with the
/// stopgap zbridge cache file (`{bizJwt, acquiredAtMs, location}`), so an
/// existing zbridge cache seeds ZGate directly.
struct MintLocation: Codable, Equatable, Sendable {
    let organizationId: String
    let projectId: String
    let apiKeyId: String
}

/// A z/login result worth persisting: the long-lived biz JWT, when it was
/// acquired, and the location it minted against. Persisting it lets chain
/// rebuilds skip `z/login` entirely — the store's 1 h access token is only
/// needed at true login (the biz JWT itself carries no `exp` claim).
struct BizSession: Codable, Equatable, Sendable {
    let bizJwt: String
    /// Millisecond epoch at which `z/login` returned this JWT.
    let acquiredAtMs: Int64
    let location: MintLocation?

    /// `z/login` `expires_in` (15552000 s = 180 d). The JWT payload has no
    /// `exp` claim, so the TTL is a client-side constant.
    static let ttlMs: Int64 = 15_552_000 * 1000
    /// The cached session is abandoned this far before its TTL ends, falling
    /// back to z/login (mirrors zbridge's 5-day margin).
    static let marginMs: Int64 = 5 * 86_400_000

    func isUsable(nowMs: Int64) -> Bool {
        bizJwt.count > 100 && nowMs < acquiredAtMs + Self.ttlMs - Self.marginMs
    }
}

/// File-backed persistence for the biz session (Application Support, 0600).
///
/// Credential material: the file is created with owner-only permissions, and
/// nothing in this type ever converts a JWT into a logged or error-carried
/// string — failures report paths only. Load is best-effort (an absent or
/// unreadable cache just means a full-path chain rebuild); save is atomic.
struct BizSessionCache {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("ModelProxy", isDirectory: true)
            .appendingPathComponent("biz-session.cache", isDirectory: false)
    }

    /// The cached session, or nil when absent, unreadable, or malformed —
    /// callers treat that as "no cache" and take the full path.
    func load() -> BizSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BizSession.self, from: data)
    }

    /// Writes the session as JSON with owner-only permissions (0600).
    /// The parent directory is created when missing.
    func save(_ session: BizSession) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
