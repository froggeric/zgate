# Claude Code settings configurator

Settings → Clients → "Claude Code settings file". ZGate reads Claude Code's
own `settings.json`, shows each key it relies on as it is against the
recommendation, and writes the differences after a confirmation and a
backup. Design and measurements:
`docs/specs/2026-11-23-claude-settings-configurator-design.md`.

## Expected Behavior

| Behavior | When | What happens |
|---|---|---|
| Status | The section is shown, and after every write or change to the recommended values | Up to date · N changes recommended · no settings file · can't be read (with the parse error's position) |
| Rows | Always | One row per managed key: current value, recommended value, an arrow where they differ |
| Context windows | Always | One line per id: the window, where it comes from (set here · from splash · default), the routed model, and the token count compaction runs at |
| Recommended ids | A tier's window is 1M or more | The id is written with `[1m]` (`opus[1m]`): the suffix pins the window to 1M whatever `CLAUDE_CODE_MAX_CONTEXT_TOKENS` says |
| Recommended ids | A tier's window is under 1M, and the `local` id | The id stays bare: `[1m]` would pin the window too high |
| Window of an id | Always | A window set in ZGate for the role, else the context length splash reports for the routed model, else the default (1M). Never below 100000 |
| Compaction | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (default 70) | Claude Code holds back 20,000 tokens of a window and compacts at that percentage of the rest: 686,000 on GLM, 169,500 on a 262,144-token local model |
| Global cap | The `local` id is on | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is recommended at the local model's window. `[1m]` ids ignore it; it protects `local` and any id typed by hand. A lower cap is kept; a higher or missing one is set |
| Global cap | No `local` id | Left alone, unless it cuts the window of a tier that carries no `[1m]`: then its removal is proposed |
| Saved settings | A tier id changes and `modelSettings.<old id>` exists | Renamed to the key without `[1m]` — the wire id. Two tiers that shared one id get a copy each |
| Local model id | `claudeSetup.localIDEnabled` | `ANTHROPIC_CUSTOM_MODEL_OPTION=local` is written; a session goes local with `/model local` or `claude --model local` |
| Local routing rule | First launch on 2.12, or "Create the rule" | Migration 13 seeds `local` → the active splash profile's model, backup relay Flash. Run-once: a deleted row stays deleted |
| Apply | "Apply recommended…" then "Apply" | The sheet lists every change (`key: old → new`), the file path, and that a backup is saved first |
| Restore | "Restore last backup…" then "Restore" | The previous file is put back; the current one is backed up first |
| Checked, never written | Always | Named in the section: a missing sign-in; `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT`, `DISABLE_COMPACT`, `autoCompactEnabled: false`; `CLAUDE_CODE_DISABLE_1M_CONTEXT` set to 1; a `local` id with no routing rule to the local model |

## Key Files

| File | Responsibility |
|------|---------------|
| `ModelProxy/Services/OrderedJSON.swift` | JSON that keeps member order and every scalar's spelling; path get/set/remove/rename |
| `ModelProxy/Services/ClaudeSetup.swift` | `ClaudeSetupRecommendation` (ids, windows, the `[1m]` rule, the cap), `ClaudeSetupPlanner` (which keys change), `ClaudeSettingsFileStore` (read, apply, backup, restore) |
| `ModelProxy/Services/ClaudeSetupReviewer.swift` | What the section shows: state, rows, id lines, what is checked and never written |
| `ModelProxy/Services/ClaudeSetupModel.swift` | Observable state; the context built from config and routes; `ClaudeSetupLocalRule` |
| `ModelProxy/Views/ClaudeSetupSection.swift` | The section and its confirmation sheets |
| `ModelProxy/Models/ClaudeSetupSettings.swift` | The `claudeSetup` config section |
| `ModelProxy/Services/ConfigStore.swift` | Migration 13 (the `local` rule) |
| `ModelProxy/Views/ClientsTabView.swift` | Where the section sits: under the Claude Code client |

## Boundary Conditions

- **A `[1m]` id needs its window written out.** With `[1m]` and no
  `modelSettings.<id>.autoCompactWindow`, Claude Code skips the compaction
  check for the id. That is why every id gets its window.
- **A session keeps the environment it was started with.** A session opened
  while the file still carried `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144` keeps
  that value after the file is edited. On a bare id it compacted at 169,500
  and was blocked at 239,000. `[1m]` ids are not affected.
- **The key of an id's saved settings, and what goes on the wire, is the id
  without `[1m]`.** Claude Code strips the suffix before sending, so ZGate
  receives `opus`, `sonnet` and `haiku`. The 1M flag it adds to the request
  never reaches z.ai from this machine (the relay route sends its own header
  set; the API-key vendor strips it).
- **`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` ignores `[1m]`** and holds every model
  to 200K. `0` is harmless.
- **The file is only written through the store:** fingerprint check against
  the preview, a backup beside the file (ten kept, mode 0600), a temporary
  file renamed over with the original's permissions. Invalid JSON is never
  written.
- **A file in one consistent style round-trips byte for byte.** Irregular
  whitespace is normalised.
- **With the aliases, a request for `opus` takes the plain row by its label**
  before any class rule, so the qwen levers and the timed twins do not catch
  it. To move a tier, edit its plain row.
- **Verified on Claude Code 2.1.323.** These are behaviours of one version.

## Change History

| Date | Change |
|------|--------|
| 2026-11-23 | Initial implementation (shipped in 2.12 (1)) |
| 2026-11-24 | Ids carry `[1m]` when their window is 1M or more; the global cap is recommended at the local model's window instead of removed (owner's finding) |
