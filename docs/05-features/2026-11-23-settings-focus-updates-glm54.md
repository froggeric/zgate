# Settings in front, working update check, GLM-5.4 routing (2026-11-23)

Five bounded changes shipped together on 2026-11-23. The configurator for
Claude Code's settings was designed separately
(`docs/specs/2026-11-23-claude-settings-configurator-design.md`) and shipped
the next day: `2026-11-24-claude-settings-configurator.md`.

## Expected Behavior

| Behavior | When | What happens |
|---|---|---|
| Settings in front | Gear in the popover | The panel is dismissed through SwiftUI's `dismiss`, ZGate switches to the regular activation policy, the Settings scene opens and is raised on a later main-loop turn. A Dock icon and a menu bar show while the window is open; the starting policy is restored when it closes |
| Back to the menu bar | Settings closes | The policy is restored at the close and read again after 0.25 s, 0.75 s and 2 s; if macOS moved it, ZGate puts it back. A check due while Settings is open again does nothing |
| Panel afterwards | Status item clicked, with Settings open or after it closed | The panel opens on the first click |
| New GLM names | Any `glm-` model id without `flash` | Classified as the main model's class (opus) and served by the opus rule. A `glm-*-flash` name stays haiku |
| Default routing | Fresh install | `auto`, `sonnet`, `opus` → relay `GLM-5.4`; `haiku` → `GLM-5.3-Flash`; catch-all → flash, backed by the api.z.ai edge |
| Migration 12 | Launch, config still on the untouched previous layout | The three plain rows (`auto`, `sonnet`, `opus` on `GLM-5.3` at the relay, no conditions, no backups) are retargeted to `GLM-5.4`. Any edit to them opts the whole set out |
| ZGate update check | Launch when the last check is over 6 h old, then daily, and Check Now | Reads `releases/latest`. The asset is `ZGate-<version>.zip` (`ZGate-2.11.3.zip` for `v2.11.3`); the tag-verbatim name is accepted too. No matching asset with a sha256 digest → `cannotCheck` |
| Popover layout | Always | No rules summary, no base-URL line. The splash lifecycle chip stays |
| Splash tab | Always | The Binary row (installed and latest version, Install or Update) is the first section |

## Key Files

| File | Responsibility |
|------|---------------|
| `ModelProxy/App/SettingsPresenter.swift` | Settings in front: dismiss-first contract, policy switch, raise with retries, restore exactly once on window close |
| `ModelProxy/Views/StatusPopover.swift` | Gear button (dismiss, then present); popover layout |
| `ModelProxy/Proxy/RouterExtensions.swift` | `ModelClass.classify` — family rule for `glm-` names |
| `ModelProxy/Models/AppConfig.swift` | Default routing (v2.2) |
| `ModelProxy/Services/ConfigStore.swift` | Migration 12 |
| `ModelProxy/Services/UpdateCenter.swift` | `ZGateRelease.zipAsset` — accepted asset names |
| `ModelProxy/Views/SplashTabView.swift` | Section order |

## Boundary Conditions

- A menu-bar app holds the foreground only while it presents as a regular
  app. `NSApp.activate()` alone does not hold once the panel is gone, and
  restoring the accessory policy early drops Settings behind the other
  windows again.
- The panel is closed through the view's `dismiss` action, never
  `NSWindow.close()`: that leaves MenuBarExtra's presentation state stale and
  swallows the next status-item click. `SettingsPresenter.present` takes the
  dismiss action as a parameter so no caller can forget it.
- If the Settings window never appears (three main-loop turns), the policy is
  restored instead of left regular.
- **A write is not a state.** macOS changes the activation policy around
  the close of an app's last window on its own. Measured on 2026-11-24 with
  a trace on an isolated copy: the policy read `.accessory` when the close
  was handled (no call from ZGate in between), and in three sessions of
  about twenty it read `.regular` again right after and the Dock icon
  stayed. So the presenter restores the policy at the close and checks it
  again at 0.25 s, 0.75 s and 2 s. A change later than two seconds after
  the close is not covered. Lesson:
  `docs/09-lessons-learned/2026-11-24-dock-icon-stayed-after-settings.md`.
- Migration 12 counts only enabled, condition-less rows: an enabled peak twin
  beside the plain row does not opt out, an extra plain row does.
- A class rule's target decides what is served. `canonicalModel` only matters
  when a rule carries no target model, and is still an enumerated list.
- The update-check regression tests carry the real `releases/latest` shape.
  The earlier fixtures used an invented asset name and stayed green while the
  check failed on every published release.
- The presenter's AppKit side and the popover layout have no unit test. They
  were verified by driving the real app through accessibility.

## Change History

| Date | Change |
|------|--------|
| 2026-11-23 | Initial version |
| 2026-11-24 | Dock icon after Settings: the policy is checked again after the close (found on 2.12 (1)) |
