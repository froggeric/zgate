import Foundation

/// One named splash serve configuration (spec §4). Fields map 1:1 onto
/// `splash serve` flags; `extraArgs` carries everything else verbatim.
struct SplashProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var model: String
    var modelDir: String?
    var draftModel: String?
    var mmproj: String?
    var extraArgs: [String]

    init(
        id: UUID = UUID(), name: String, model: String,
        modelDir: String? = nil, draftModel: String? = nil, mmproj: String? = nil,
        extraArgs: [String] = []
    ) {
        self.id = id; self.name = name; self.model = model
        self.modelDir = modelDir; self.draftModel = draftModel; self.mmproj = mmproj
        self.extraArgs = extraArgs
    }

    /// Argv after the binary path. Only non-nil fields become flags;
    /// `extraArgs` last so per-splash argparse semantics let them override.
    func launchArguments() -> [String] {
        var args = ["serve", "--model", model]
        if let modelDir { args += ["--model-dir", modelDir] }
        if let draftModel { args += ["--draft-model", draftModel] }
        if let mmproj { args += ["--mmproj", mmproj] }
        args += extraArgs
        return args
    }

    /// Serve argv at a configured port: the profile's own flags plus
    /// `--port <port>` when the args don't already carry a port in either
    /// `--port X` or `--port=X` form (an explicit profile port wins —
    /// extraArgs keep their documented override semantics).
    func serveArguments(port: Int) -> [String] {
        var args = launchArguments()
        if !args.contains("--port") && !args.contains(where: { $0.hasPrefix("--port=") }) {
            args += ["--port", String(port)]
        }
        return args
    }

    // Tolerant decode (same pattern as ModelMapping): every key optional.
    enum CodingKeys: String, CodingKey {
        case id, name, model, modelDir, draftModel, mmproj, extraArgs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decode(String.self, forKey: .model)
        modelDir = try? c.decode(String.self, forKey: .modelDir)
        draftModel = try? c.decode(String.self, forKey: .draftModel)
        mmproj = try? c.decode(String.self, forKey: .mmproj)
        extraArgs = (try? c.decode([String].self, forKey: .extraArgs)) ?? []
    }
}

/// Splash supervision settings stored under `AppConfig.splash` (spec §4).
/// Absent section = defaults; seeded on first config write / migration.
struct SplashSettings: Codable, Equatable, Sendable {
    var keepRunning: Bool
    var activeProfileID: UUID?
    var profiles: [SplashProfile]
    var binaryPathOverride: String?
    /// Local port the splash server binds (`--port`) and ZGate probes.
    /// Default moved off 8000 (2026-11-18): it collided with local
    /// webservers. Old configs without the key decode to the default.
    var port: Int

    init(
        keepRunning: Bool = true, activeProfileID: UUID? = nil,
        profiles: [SplashProfile] = [], binaryPathOverride: String? = nil,
        port: Int = 8123
    ) {
        self.keepRunning = keepRunning
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.binaryPathOverride = binaryPathOverride
        self.port = port
    }

    // Tolerant decode (SplashProfile's pattern): keys absent from
    // pre-port configs fall back to defaults instead of failing the
    // whole config decode (which would reset everything to defaults).
    enum CodingKeys: String, CodingKey {
        case keepRunning, activeProfileID, profiles, binaryPathOverride, port
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepRunning = (try? c.decode(Bool.self, forKey: .keepRunning)) ?? true
        activeProfileID = try? c.decode(UUID.self, forKey: .activeProfileID)
        profiles = (try? c.decode([SplashProfile].self, forKey: .profiles)) ?? []
        binaryPathOverride = try? c.decode(String.self, forKey: .binaryPathOverride)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 8123
    }

    /// The profile `activeProfileID` names; a dangling id (hand-edited
    /// config, deleted profile) falls back to the first profile.
    var activeProfile: SplashProfile? {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first
    }

    /// Owner-machine seed (spec §4): the exact splash-m1 invocation serving
    /// qwen3.8-27b-q8 today (spec §2's observed command). qwen4 later = a
    /// second profile added in Settings, zero code change.
    static func defaultSeeded() -> SplashSettings {
        let qwen = SplashProfile(
            name: "Qwen3.8-27B Q8",
            model: "local/qwen3.8-27b-q8",
            modelDir: "/Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf",
            draftModel: "/Volumes/ssd/ai/cache/misc/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/015e795645c74b1a0eeef3b570031fb62e769bc5",
            mmproj: "/Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/mmproj-F16.gguf",
            extraArgs: [
                "--persistent-cache", "--cache-dir", "/Volumes/ssd/ai/cache/splash",
                "--max-cache-disk", "20G"])
        return SplashSettings(keepRunning: true, activeProfileID: qwen.id, profiles: [qwen])
    }
}
