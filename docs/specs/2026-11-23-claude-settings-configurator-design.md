# Claude Code settings configurator — design

- Date: 2026-11-23
- Status: draft, waiting for review
- Branch: `feat/status-popover-updates-defaults`
- Owner decisions (2026-11-23): write into `~/.claude/settings.json` (approach A); apply the recommended setup to this machine's file once built; include the dedicated local model id now.

## Problem

Two couplings break at every model launch:

1. Claude Code's settings name GLM models (`glm-5.4[1m]`, `glm-5.3-flash[1m]`).
   Every z.ai launch means editing `~/.claude/settings.json`, and every edit is
   a chance to misroute. On 2026-11-23 the main thread ran on Flash for hours
   with no error and no warning.
2. Nothing says whether Claude Code is pointed at ZGate or carries the settings
   ZGate relies on. `CLAUDE_CODE_GATEWAY_HINT_HEADERS` is unset on this machine,
   so the traffic list cannot label request classes.

The README already notes that the `CLAUDE_CODE_MAX_CONTEXT_TOKENS` cap is
inert for `[1m]` aliases. Measured while working on this: in that mode
nothing arms proactive compaction at all, while the bare aliases make the
same cap effective.

## Goals

- One place in ZGate that shows whether Claude Code is set up for ZGate, applies
  the recommended setup, or lets each value be set by hand.
- Stable model ids, so that neither a z.ai launch nor a Claude Code update needs
  a Claude settings edit. Which GLM model answers is decided only by ZGate's
  rule table.
- A correct context window for every id Claude Code can ask for, including the
  local model.
- `~/.claude/settings.json` is never damaged. It holds secrets and settings that
  are nobody else's business.

## Non-goals

- Project, local or managed settings files; other tools (Codex); `CLAUDE.md`.
- Effort, timeout, telemetry, permission or plugin settings.
- Writing without an explicit confirmation. A silent "fix" is not offered.
- A "Verify routes" button (probe each tier, show which model answered).

## Evidence

Measured on 2026-11-23 with Claude Code 2.1.323 against a local stub, reading
`autocompact: … effectiveWindow=N` from `--debug-file`.

| Value in settings.json | Sent on the wire | Compaction window |
|---|---|---|
| `glm-5.4[1m]` | `glm-5.4` + 1M beta | none armed; the 262144 cap is not applied |
| `opus`, `sonnet`, `haiku` | same, verbatim | 242144 with the 262144 cap; no notice |
| `local` (`ANTHROPIC_CUSTOM_MODEL_OPTION=local`) | `local` | per id: `modelSettings.local.autoCompactWindow=120000` → 100000 |
| same, window 60000 | `local` | ignored: 980000 and the "assumes 1m" notice |

- `modelSettings` entries match the requested id: `glm-5.3-flash` matches
  `glm-5.3-flash[1m]`, `haiku` matches `haiku`. A tier id that changes without
  its key loses the saved effort level.
- `CLAUDE_CODE_AUTO_MODE_MODEL=haiku` is honoured (classifier request is
  `model: haiku`, max_tokens 2112, no tools). Unset, it follows
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, the main model, then falls back to opus.
- `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1` sends `x-claude-code-request-class`,
  which ZGate already reads (`ProxyForwarder.swift:732`).
- A cap set in settings.json beats the same variable in the launching shell.
- The per-id window has a 100000 floor; the global cap does not
  (`60000` → 40000).

## Design

### 1. Recommended setup

The recommended values live in ZGate's config, not in code, so a different
preference is a setting and not permanent drift:

```json
"claudeSetup": {
  "opusID": "opus", "sonnetID": "sonnet", "haikuID": "haiku",
  "localIDEnabled": false
}
```

Defaults are the bare aliases. The local id itself is the constant `local`.
"Tolerant decode" like the other sections: absent keys fall back to defaults.

### 2. Managed keys

"Current" is read from `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`).
"Recommended" comes from section 1 and the bound port of the client whose name
contains "claude".

| Key | Recommended | Why |
|---|---|---|
| `env.ANTHROPIC_BASE_URL` | `http://127.0.0.1:<bound port>` | Points Claude Code at ZGate. Equal ignoring trailing slashes, so `…:8787/` is not a change |
| `env.ANTHROPIC_DEFAULT_OPUS_MODEL` | `opusID` | Tier ids never change at a launch |
| `env.ANTHROPIC_DEFAULT_SONNET_MODEL` | `sonnetID` | same |
| `env.ANTHROPIC_DEFAULT_HAIKU_MODEL` | `haikuID` | same |
| `env.CLAUDE_CODE_AUTO_MODE_MODEL` | `haikuID` | Classifier follows the fast tier |
| `env.CLAUDE_CODE_GATEWAY_HINT_HEADERS` | `1` | Traffic list can label request classes |
| `env.ANTHROPIC_CUSTOM_MODEL_OPTION`, `…_NAME` | `local`, `Local model (ZGate)` | Only while `localIDEnabled` |
| `modelSettings.<tier id>` | renamed from the old id | Saved effort levels survive an id change |
| `modelSettings.local.autoCompactWindow` | splash's context length | Only while `localIDEnabled` and the length is ≥ 100000 |

Shown and editable, never recommended:

- `env.CLAUDE_CODE_MAX_CONTEXT_TOKENS` — the cost rule belongs to the user.
- `modelSettings.<id>.autoCompactWindow` for the three tiers.

Checked only: one of `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`
must be present or Claude Code will not start. If none is, the section offers
"Set a placeholder token" (`zgate-local-proxy`) behind its own confirmation.
Values are never shown.

A rename is proposed when a tier id changes from X to Y, `modelSettings.X`
exists and `modelSettings.Y` does not.

### 3. Writing rules

- Only managed keys are written. Every other byte stays as it was: key order,
  indentation and number spelling are kept. A small ordered JSON type parses
  the file into ordered members and keeps each number as written.
- A write is one confirmed transaction:
  1. Re-read the file and compare a fingerprint with the previewed one. If it
     changed, stop: "The file changed since this preview."
  2. Copy it to `settings.json.zgate-backup-<yyyyMMdd-HHmmss>` beside it. The
     ten newest backups are kept.
  3. Write a temporary file in the same directory with the original's
     permissions (0600 for a new file), then rename it over.
- "Restore last backup" is itself a confirmed write, and backs up the current
  file first.
- The file is never held in memory for writing; every action re-reads it.
- The model re-reads when the popover opens and after every write, so edits made
  by Claude Code (`/effort`, `/autocompact`) or by hand show up.

### 4. Where it lives

A section "Claude Code settings file" in Settings → Clients, under the Claude
Code client. The tab bar already holds ten tabs; no eleventh.

- Status: up to date · N changes recommended · no settings file · can't be read.
- One row per managed key: current value, recommended value, and whether they
  differ. Secrets show as "set" or "not set".
- "Apply recommended…" opens a confirmation sheet listing `key: old → new`, the
  file path and the backup name.
- "Copy recommended block" puts the managed keys as JSON on the clipboard, for
  anyone who would rather merge by hand.
- "Restore last backup…" (confirmation).
- "Reveal in Finder".
- A disclosure "Recommended values" edits the ids of section 1.
- A disclosure "Context window" holds the keys listed under "shown and editable,
  never recommended".
- A disclosure "Local model id" (section 6).

Footer: writes only the keys above; a backup is saved before every write;
project and managed settings can override these values; applies to new sessions;
verified with Claude Code 2.1.323.

### 5. Popover banner

The popover gets one orange banner, only when something is wrong:

| State | Text | Action |
|---|---|---|
| differs | "Claude Code settings differ from ZGate's setup" | Review… |
| no settings file | "No Claude Code settings file found" | Set up… |
| can't be read | "Claude Code settings file can't be read" | Open Settings… |

The action dismisses the panel and opens Settings on the Clients tab, through
`SettingsPresenter`. For that, `SettingsView` binds its tab selection to a
shared value the presenter sets before opening. Dismissing (×) hides the banner
for the session. Nothing is persisted and the menu-bar icon shows no badge:
this is advice, not a fault.

### 6. Local model id

Claude Code sizes the context window from the requested id, so a local model
needs an id of its own.

- ZGate seeds one exact-match rule: `local` → the active splash profile's model
  at the splash vendor, backup `GLM-5.3-Flash` on the relay, enabled. Nobody
  sends `local` unless Claude Code is told to, so an enabled rule changes no
  existing route. It follows the splash-down-means-backup behaviour of the
  existing qwen levers, and the section says so.
- Seeded once, guarded by a `localRuleSeeded` marker (the pattern of migrations
  10 and 11): a user who deletes the row keeps it deleted.
- A session goes local with `/model local` or `claude --model local`.
- The section reads the model's `context_length` from splash's `/v1/models`
  when splash is running; otherwise the number is typed.
  - 100000 or more: recommended `modelSettings.local.autoCompactWindow = N`.
  - Less than 100000: Claude Code cannot give one model that small a window. The
    section says so and offers "Lower the global cap to N for every session" as
    a separate, labelled action.
- If the active profile changes, the section shows "Rule target is out of date"
  with a one-click sync, which edits the ZGate rule only.

### 7. Data model changes

- `AppConfig.claudeSetup: ClaudeSetupSettings?` and
  `AppConfig.localRuleSeeded: Bool` (both optional-tolerant in the decoder).
- `ClaudeSetupSettings`: `opusID`, `sonnetID`, `haikuID`, `localIDEnabled`.
- Migration 13 seeds the `local` rule.
- New code: an ordered JSON value type; a settings-file store (read, plan,
  apply, backup, restore); a `@Observable` setup model (state, plan, banner
  dismissal); the Clients-tab section; the popover banner.

### 8. Errors

| Situation | Behaviour |
|---|---|
| File missing | State "no settings file". Apply creates it with the managed keys, mode 0600, after confirmation |
| Invalid JSON | Never written. State "can't be read", with the parse error's position |
| Changed since preview | No write; the diff is rebuilt and shown again |
| Permission or I/O failure | Error line in the section; the file is left as it was |
| Backup missing | "Restore" disabled with the reason |

### 9. Testing

Unit tests, written first:

- Ordered JSON: round-trip is byte-identical on a fixture shaped like the real
  file (nested permissions, booleans, numbers, non-ASCII, no trailing newline);
  2-space, 4-space and tab indents; a managed-key edit leaves every other byte
  unchanged.
- Plan: table-driven over each managed key (same, differs, missing, base URL
  with and without trailing slash, rename proposed and not proposed).
- Apply: backup exists and equals the previous file; permissions preserved;
  refusal on invalid JSON; refusal when the file changed; idempotent second
  apply; restore round-trip; backup pruning.
- Model: state per situation; banner dismissal is session-only.
- Routing: `local` lands on the splash target, and on the relay backup when
  splash is unhealthy.
- Migration 13: seeds once, never resurrects a deleted row.

The two surfaces have no unit test. They are verified by driving the real app
through accessibility, as item 1 of the same branch was.

### 10. Verification on this machine

1. Dry run against a copy of the real file with secrets removed: the diff lists
   exactly the expected keys and nothing else.
2. Apply to the real file (approved by the user on 2026-11-23).
3. Run Claude Code once against the stub with that file: wire ids are the
   aliases, `effectiveWindow=242144`.
4. Probe the relay through ZGate: `opus` and `sonnet` answer `GLM-5.4`, `haiku`
   answers `GLM-5.3-Flash`.
5. Propose the matching edits to the global `CLAUDE.md` tier table. Not before.

## Risks

- Claude Code rewrites the file itself. Handled by re-reading before every write
  and the fingerprint check.
- These are behaviours of one Claude Code version. The footer names the version
  they were measured on; the memory note carries the details.
- A project-level `env` can override the user-level one. Stated in the footer;
  not detected.

## Out of scope, recorded

- "Verify routes" probe button.
- Detecting project or managed overrides.
- A `behavesAs` `modelPicker` row. It would remove the "unrecognized model"
  notice but switches requests to that Claude model's shape (128000 max tokens,
  extra betas), which is untested against GLM.
