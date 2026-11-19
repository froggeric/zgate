import Foundation

/// Machine-level splash storage/cache settings (spec §3.6). Not per-profile:
/// disk layout is a machine concern. Emitted BEFORE profile extraArgs —
/// extraArgs keep their documented last-word override.
struct SplashStorage: Codable, Equatable, Sendable {
    /// HF download cache override → HF_HUB_CACHE env at launch.
    /// nil = splash default (~/.cache/huggingface/hub).
    var modelCacheLocation: String?
    /// → --persistent-cache (enables --cache-dir).
    var persistentCache: Bool = false
    /// → --cache-dir (only emitted when persistentCache).
    var cacheDir: String?
    /// → --max-cache-disk; nil = auto (no flag); "0" = off; e.g. "16G".
    var maxCacheDisk: String?
    /// → --max-cache-disk-writes; nil = no flag (no budget).
    var maxCacheDiskWrites: String?

    init(
        modelCacheLocation: String? = nil, persistentCache: Bool = false,
        cacheDir: String? = nil, maxCacheDisk: String? = nil,
        maxCacheDiskWrites: String? = nil
    ) {
        self.modelCacheLocation = modelCacheLocation
        self.persistentCache = persistentCache
        self.cacheDir = cacheDir
        self.maxCacheDisk = maxCacheDisk
        self.maxCacheDiskWrites = maxCacheDiskWrites
    }

    var launchFlags: [String] {
        var f: [String] = []
        if persistentCache { f.append("--persistent-cache") }
        if persistentCache, let cacheDir, !cacheDir.isEmpty { f += ["--cache-dir", cacheDir] }
        if let maxCacheDisk, !maxCacheDisk.isEmpty { f += ["--max-cache-disk", maxCacheDisk] }
        if let maxCacheDiskWrites, !maxCacheDiskWrites.isEmpty {
            f += ["--max-cache-disk-writes", maxCacheDiskWrites]
        }
        return f
    }

    var environment: [String: String]? {
        guard let modelCacheLocation, !modelCacheLocation.isEmpty else { return nil }
        return ["HF_HUB_CACHE": modelCacheLocation]
    }

    /// Migration 8: lift recognized cache flags out of extraArgs (both
    /// `--flag X` and `--flag=X`). Unknown flags untouched.
    static func lift(from extraArgs: inout [String]) -> SplashStorage {
        var s = SplashStorage()
        var i = 0
        func value(form: String) -> String? {
            if extraArgs[i] == form, i + 1 < extraArgs.count {
                defer { extraArgs.remove(at: i + 1) }
                return extraArgs[i + 1]
            }
            if extraArgs[i].hasPrefix(form + "=") {
                return String(extraArgs[i].dropFirst(form.count + 1))
            }
            return nil
        }
        while i < extraArgs.count {
            let a = extraArgs[i]
            if a == "--persistent-cache" {
                s.persistentCache = true; extraArgs.remove(at: i)
            } else if let v = value(form: "--cache-dir") {
                s.cacheDir = v; extraArgs.remove(at: i)
            } else if let v = value(form: "--max-cache-disk") {
                s.maxCacheDisk = v; extraArgs.remove(at: i)
            } else if let v = value(form: "--max-cache-disk-writes") {
                s.maxCacheDiskWrites = v; extraArgs.remove(at: i)
            } else { i += 1 }
        }
        return s
    }

    // Tolerant decode (SplashProfile's pattern): keys absent from
    // pre-storage configs fall back to defaults instead of failing decode.
    enum CodingKeys: String, CodingKey {
        case modelCacheLocation, persistentCache, cacheDir, maxCacheDisk, maxCacheDiskWrites
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelCacheLocation = try? c.decode(String.self, forKey: .modelCacheLocation)
        persistentCache = (try? c.decode(Bool.self, forKey: .persistentCache)) ?? false
        cacheDir = try? c.decode(String.self, forKey: .cacheDir)
        maxCacheDisk = try? c.decode(String.self, forKey: .maxCacheDisk)
        maxCacheDiskWrites = try? c.decode(String.self, forKey: .maxCacheDiskWrites)
    }
}
