import Foundation

/// Reads the z.ai API key that powers the quota monitor endpoint
/// (`api.z.ai/api/monitor/usage/quota/limit`, live-verified 2026-11-16) from
/// the Claude Code settings file — the same key Claude Code itself authentic
/// with, so ZGate holds no second copy of a secret.
///
/// Spec §7 ("no secrets in config") is honored by storing only the PATH to
/// the settings file in ZGate's config; the key itself is read at poll time,
/// held in memory for the duration of the request, and never logged — every
/// failure path reports the file location and which step failed, never a
/// value read out of the file.
enum MonitorAPIKeyReader {

    enum ReaderError: Error, LocalizedError, Equatable {
        case unreadable(path: String)
        case malformed(path: String)
        case absent(path: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path):
                return "quota API key: settings file unreadable at \(path)"
            case let .malformed(path):
                return "quota API key: settings file at \(path) is not a JSON object with env.ANTHROPIC_AUTH_TOKEN"
            case let .absent(path):
                return "quota API key: no env.ANTHROPIC_AUTH_TOKEN in \(path)"
            }
        }
    }

    /// Claude Code's default settings location.
    static func defaultSettingsURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json", isDirectory: false)
    }

    /// The API key from the settings file's `env.ANTHROPIC_AUTH_TOKEN`, or a
    /// typed error. The key value travels only in the return value.
    static func apiKey(at settingsURL: URL) throws -> String {
        guard let data = try? Data(contentsOf: settingsURL) else {
            throw ReaderError.unreadable(path: settingsURL.path)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let env = json["env"] as? [String: Any]
        else {
            throw ReaderError.malformed(path: settingsURL.path)
        }
        guard let key = env["ANTHROPIC_AUTH_TOKEN"] as? String, !key.isEmpty else {
            throw ReaderError.absent(path: settingsURL.path)
        }
        return key
    }
}
