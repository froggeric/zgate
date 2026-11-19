# Splash Chip Variants, Update Center, Storage Management

Implements `docs/specs/2026-11-19-splash-variants-updates-storage-design.md` (2026-11-19).

## Expected Behavior

| Behavior | When | What happens |
|---|---|---|
| Per-chip splash support | Always | M1/M2 → paperniuk/splash fork (`splash-m1` shim); M3+ → incoai/splash official (brew `splash`). One `SplashChip` table drives binary resolution (`override → /opt/homebrew/bin/<name> → ~/.local/bin/<name> → app-support bin/<name>`), the latest-version check's repo, install/update paths, and the install row's labels |
| macOS gate | `ProcessInfo.operatingSystemVersion < 26.4` | Install row explains `splash needs macOS 26.4+` and disables actions; auto-apply refuses once per tag (session `refusedApplyTag`) instead of flapping |
| Fork install/update | M1/M2, install button / auto-apply | Tarball `splash-<tag>-arm64-macos26.tar.gz` + `.sha256` (whitespace-trimmed) → SHA-256 verify BEFORE disk → `tar --strip-components 1` → quarantine strip → version-dir replace + atomic `current` symlink swap → shim write (legacy binary backed up to `splash-m1.zgate-legacy`) → prune keeps current + 1 → `--version` verify. Replaced the pre-2026-11-19 direct-binary path that current fork releases (tarball + sidecar assets) had made dead |
| Version checks | Launch +30 s when last check > 6 h, then every 24 h; manual Check Now | Installed version from `release.json` (fork `Splash-M1/current/`, brew Cellar walk-up) with `--version` fallback, vs the chip repo's `releases/latest`. ZGate itself vs `froggeric/zgate/releases/latest` (repo public since 2026-11-19). Every failure degrades to `unknown`/`cannotCheck` — never a fabricated verdict |
| Update alert | Update available and tag ≠ dismissed tag | Badge dot on the menu-bar quota ring (fault symbols still replace the whole icon and outrank it) + popover banners + About Updates row. Dismissal is per-tag and expires on a newer tag |
| Splash auto-apply | Update available + splash stopped + "Update splash automatically" on | Applies via the fork tarball installer / `brew upgrade`. Owned-running defers to the next stop or start; adopted/external never touched. Toggling the setting off voids a pending apply. Post-apply verify must answer the new tag else a non-alerting `splash update failed — <reason>` line shows in the popover with a retry action |
| ZGate self-update | Explicit click only, ever | Check is anonymous; Install… (About or popover, /Applications installs only) confirms the proxy-down warning, then downloads `ZGate-<tag>.zip`, verifies the GitHub sha256 digest AND the staged TeamID, and runs the bundled `scripts/release-swap.sh` (validates, SIGTERMs the app, swaps with backup + rollback, reopens). Non-/Applications installs get a View… → Releases link. Never silent, never automatic |
| Toggles | General tab | "Check for updates automatically" is live in the 24 h loop (off stops scheduled checks at the next cycle boundary, on resumes — no relaunch); "Update splash automatically when stopped" respected by every automatic path (manual buttons unaffected) |
| Storage settings | Splash tab → Storage | Model cache (HF download) location with Change…/Move…(stopped-gated; ditto + du-verify + `.zgate-moved-<ts>` backup; "Delete old location" is a separate explicit action)/Reveal/Clear…; prefix-cache persistent toggle + `--cache-dir` picker (gated) + quota Auto/Off/Custom (`^\d+(\.\d+)?[KMG]$`; invalid keystrokes keep the last valid value) + daily write budget; live usage from `/status` `disk` while running; Clear prefix cache removes only 32-hex namespace dirs, stopped-only |
| Storage launch wiring | splash serve | Storage flags emit between profile flags and `extraArgs` (extraArgs keep the last word); `HF_HUB_CACHE` injected into the child env when a model-cache location is set. One-shot migration 8 lifted the seeded profile's hand-written cache flags into `splash.storage` |
| Splash vendor port sync | Routing | The splash vendor's baseURL derives from `SplashSettings.port` at snapshot build (start + reload, in-memory only) — closing the hardcoded-8123 desync; health probes follow the synced array |
| About credits | About tab | Splash repos credited: incoai/splash (Apache-2.0) and the paperniuk M1/M2 port (Apache-2.0) |

## Key Files

| File | Responsibility |
|------|---------------|
| `ModelProxy/Services/SplashInstaller.swift` | `SplashChip` variant table (names, repos, releases URL, macOS gate), `SplashVersion` (fork-patch 4-component ordering), `latestRelease(for:)`, `brewArguments`, `installedVersion` |
| `ModelProxy/Services/SplashTarballInstaller.swift` | Fork tarball install/update (checksum, unpack, symlink swap, shim, prune, verify) |
| `ModelProxy/Services/UpdateCenter.swift` | Check cadence, splash/ZGate states, per-tag dismissal, auto-apply engine (`evaluateAutoApply`, `applySplashUpdate`, refusal memory), `UpdateCadence`, `ZGateVersion` |
| `ModelProxy/Services/AppUpdateService.swift` | ZGate release fetch, digest+TeamID staging, detached swap via bundled script, shared `ZGateInstallFlow` |
| `ModelProxy/Services/SplashStatusClient.swift`, `ModelProxy/Services/StorageActions.swift` | `/status` disk decode; namespace-safe clear, verified move |
| `ModelProxy/Models/SplashStorage.swift`, `ModelProxy/Models/UpdateSettings.swift` | Persisted shapes (tolerant decode), storage flag emission, extraArgs lift |
| `ModelProxy/Models/SplashSettings.swift`, `ModelProxy/Services/ConfigStore.swift` | `serveArguments(port:storage:)`; migration 8 |
| `ModelProxy/Services/SplashManager.swift` | Per-chip resolution, storage env injection, `preStartUpdateGate`/`ownedStoppedHook` |
| `ModelProxy/Views/QuotaMenuBarIcon.swift`, `StatusPopover.swift`, `SettingsView.swift`, `GeneralTabView.swift`, `SplashTabView.swift`, `SplashStorageSection.swift` | Badge, banners, About Updates + credits, toggles, install row + macOS gate, storage UI |
| `ModelProxy/Models/AppConfig.swift`, `ModelProxy/Proxy/ProxyServer.swift` | `syncingSplashVendor` port sync at snapshot build |
| `scripts/release-swap.sh` | Bundled swap script (Copies into `Contents/Resources` via the app target's Resources phase — same file run by hand) |

## Boundary Conditions

- Both splash repos require macOS 26.4+; ZGate itself runs on 15.7+ — the gate degrades splash install/update only.
- Without `--persistent-cache` the SSD cache lives in `$TMPDIR` and ignores `--cache-dir`; the Storage UI gates the picker the same way the flag semantics do. `--max-cache-disk` is NOT persistent-gated (it sizes the SSD cache either way).
- Existing downloads are never moved by splash itself; the Move action copies + verifies and leaves a deletable `.zgate-moved-<ts>` backup — deletion is always a separate user action.
- Update checks: 2 anonymous GitHub calls per cycle (60/h shared per IP); `lastCheckAt` bumps even on degraded cycles (no retry storms).
- A failed ZGate stage leaves `updates/<tag>/` until the next stage of the same tag removes it first.
- Old `config.json` (no `splash.storage`, no `update` section) loads unchanged with defaults.

## Change History

| Date | Change |
|------|--------|
| 2026-11-19 | Initial version — full wave per `docs/specs/2026-11-19-splash-variants-updates-storage-design.md`: per-chip variants, tarball installer (replacing the dead binary path), UpdateCenter + auto-apply, explicit-click self-update, storage settings + migration, badge/banners, credits, port-desync fix |
