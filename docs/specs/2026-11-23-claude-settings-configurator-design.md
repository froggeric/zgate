# Claude Code settings configurator — design

- Date: 2026-11-23 (v3 on 2026-11-24; replaces the v1 and v2 drafts)
- Status: v3 — built, shipped in 2.12 (1)
- Branch: `feat/claude-settings-configurator`
- Owner decisions kept from v1: write into `~/.claude/settings.json`; apply
  the recommended setup to this machine once built; include the local model id.

## Requirements

The owner's four requirements (2026-11-23), and the correction of 2026-11-24:

1. A model routed to GLM: Claude Code uses a 1M context window.
2. A model routed to a local model: Claude Code uses that model's window
   (262144 for qwen 3.8).
3. Compaction happens at the right percentage of the current window.
4. Ideally the ids are `opus` / `sonnet` / `haiku`, with `[1m]` if it helps.
5. Correction: `[1m]` is needed. With bare ids the owner saw Claude Code
   refuse at a full context or force a compaction.
6. The global cap goes back, set to the local model's window: `[1m]` takes
   care of the GLM models, the cap takes care of everything bare.

## What Claude Code does

Measured on 2026-11-23 and 2026-11-24 with Claude Code 2.1.323 against a
local stub: `--debug-file` for `autocompact: … effectiveWindow=N` and the
logged threshold, token counts faked in the stub's `usage`; and the bundle's
own logic for the same functions.

| Session on | Window Claude Code uses | Compacts at |
|---|---|---|
| `opus[1m]` + window 1000000 | 1,000,000 | 686,000 (with the 70% variable) |
| `opus[1m]` + window 1000000 + a 262,144 cap in the environment | 1,000,000 | 686,000: the cap is ignored |
| `opus` + window 1000000, no cap | 1,000,000 | 686,000 |
| `opus` + window 1000000 + a 262,144 cap in the environment | 262,144 | forced at 169,500; blocked at 239,144 |
| `opus[1m]`, no window | 1,000,000 | the check is skipped |
| `local` + window 262144 | 262,144 | 169,500 |
| `opus[1m]` + `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` | 200,000 | blocked at 177,000 |
| `local` + the 262,144 cap, no window | 262,144 | 169,500 |
| bare `glm-5.5` typed by hand + the 262,144 cap | 262,144 | 169,500 |
| bare `glm-5.5` typed by hand, no cap | 1,000,000 | 686,000 |

The rules behind the table:

- **`[1m]` pins an id's window to 1M.** Claude Code takes the largest of the
  cap, the catalog and 1M for such an id.
- **A bare id takes `CLAUDE_CODE_MAX_CONTEXT_TOKENS`**, wherever the value
  comes from. A session keeps the environment it was started with: one
  started while the file still carried a cap keeps that cap after the file is
  edited. That is what the owner ran into — and the reason the cap is the
  right protection for the ids that carry no `[1m]`.
- **A `[1m]` id needs its window written out.** With no window set for the
  id, the compaction check is skipped for it. `modelSettings.<id>.autoCompactWindow`
  turns the check back on. This is what the v2 draft missed: its probes never
  combined `[1m]` with a window, and concluded that `[1m]` always switched
  compaction off.
- **The effective window is the window minus 20,000**, held back for the
  reply. Claude Code refuses to continue at the window minus 23,000.
- **Compaction runs at a percentage of the effective window.** Without
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` it leaves 13,000 (967,000 of 980,000).
- **The key of an id's saved settings, and what goes on the wire, is the id
  without `[1m]`**: Claude Code strips the suffix before sending, and ZGate
  receives `opus`, `sonnet` and `haiku` as before. The 1M flag it adds to the
  request never reaches z.ai from this machine (ZGate's relay route sends its
  own header set; the API-key vendor strips it).
- `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` ignores `[1m]` and holds every model to
  200K. `0` is harmless.

GLM's window is 1M: z.ai states a 1M context and 128K maximum output for
GLM-5.4 and GLM-5.3-Flash. This session itself ran at 422,000 tokens on the
relay. Not probed above that.

Re-verify after a Claude Code upgrade; these are behaviours of one version.

## Recommended setup

```json
"env": {
  "ANTHROPIC_BASE_URL": "http://127.0.0.1:<bound port>",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus[1m]",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "sonnet[1m]",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku[1m]",
  "CLAUDE_CODE_AUTO_MODE_MODEL": "haiku[1m]",
  "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1",
  "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70",
  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
},
"modelSettings": {
  "opus":   { "autoCompactWindow": 1000000 },
  "sonnet": { "autoCompactWindow": 1000000 },
  "haiku":  { "autoCompactWindow": 1000000 },
  "local":  { "autoCompactWindow": 262144 }
}
```

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is the local model's window: `[1m]` ids
ignore it, and it protects `local` and any id typed by hand. Result on this
machine:

| Claude Code asks for | ZGate serves | Window | Compacts at |
|---|---|---|---|
| `opus[1m]`, `sonnet[1m]`, `haiku[1m]` | GLM through the relay | 1,000,000 | 686,000 |
| `local` | qwen 3.8 on splash | 262,144 | 169,500 |

**Why 70%.** It leaves 30% of the window (300,000 on GLM) for the reply and
for whatever one step adds, so the model's limit is not reached before
compaction. It needs about 7% fewer compactions than 65%, and each compaction
re-sends the conversation and loses detail. It is far below Claude Code's own
default (96.7%), where a session costs 41% more per call and sits within one
large step of the limit. 65% costs about 7% less per call near the threshold;
it is one value in ZGate's settings.

## Where the recommended values come from

ZGate's config, so a different preference is a setting:

```json
"claudeSetup": {
  "opusID": "opus", "sonnetID": "sonnet", "haikuID": "haiku",
  "localIDEnabled": true,
  "defaultContextWindow": 1000000,
  "compactPercent": 70,
  "contextWindows": { "opus": 1000000 }
}
```

- The ids are stored without `[1m]`.
- **`[1m]` is added to an id whose window is 1,000,000 or more, and left off
  below.** The suffix pins the window to 1M: right for GLM, wrong for a
  262,144-token local model. A `[1m]` typed into a setting is normalised the
  same way.
- **The window of an id follows the model ZGate routes it to** — by the wire
  id, the one without the suffix:
  1. `contextWindows[<role>]` when set (`opus`, `sonnet`, `haiku`, `local`).
  2. The routed target is a splash model and splash reports its
     `context_length`: that number.
  3. Otherwise `defaultContextWindow`.
- The route is the primary target of the first eligible rule for the id, read
  from a routing snapshot built from the current config.
- A window under 100000 is raised to 100000: Claude Code cannot set one model
  lower.

## Managed keys

"Current" is read from `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`).
"Recommended" comes from the section above and the bound port of the client
whose name contains "claude".

| Key | Recommended | Why |
|---|---|---|
| `env.ANTHROPIC_BASE_URL` | `http://127.0.0.1:<bound port>` | Points Claude Code at ZGate. Equal ignoring trailing slashes |
| `env.ANTHROPIC_DEFAULT_OPUS_MODEL` | `opus[1m]` when its window is 1M | The tier ids never change at a launch; `[1m]` pins the window |
| `env.ANTHROPIC_DEFAULT_SONNET_MODEL` | same for sonnet | same |
| `env.ANTHROPIC_DEFAULT_HAIKU_MODEL` | same for haiku | same |
| `env.CLAUDE_CODE_AUTO_MODE_MODEL` | the haiku id | The classifier follows the fast tier |
| `env.CLAUDE_CODE_GATEWAY_HINT_HEADERS` | `1` | The traffic list can label request classes |
| `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `"<compactPercent>"` | Requirement 3 |
| `modelSettings.<id>.autoCompactWindow` (key without `[1m]`) | the id's window | Requirements 1, 2 and the check for `[1m]` ids |
| `modelSettings.<old id>` | renamed to the new key | Saved effort levels survive an id change |
| `env.CLAUDE_CODE_MAX_CONTEXT_TOKENS` | the largest window among the ids without `[1m]`: the local model's, normally | `[1m]` ids ignore it; it protects `local` and any id typed by hand. A lower cap is kept as the owner's; a higher or missing one is set. With no local id it is left alone, unless it cuts a bare tier's window |
| `env.ANTHROPIC_CUSTOM_MODEL_OPTION` | `local` | Only while `localIDEnabled` |

The three `ANTHROPIC_DEFAULT_*_MODEL` keys are written even when the value
looks like a no-op. With a key absent, Claude Code substitutes its own Claude
id and ignores windows set for the alias.

A rename is proposed when a tier id changes from X to Y, `modelSettings.X`
exists and `modelSettings.Y` does not. X is the file's current value with any
`[1m]` removed; Y is the new id without it. Two tiers that shared one id get
a copy each.

## Checked, never written

- **Sign-in:** one of `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`
  must be present. If none is, the section says so. Values are never shown.
- **Keys that switch compaction off:** `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT`,
  `DISABLE_COMPACT`, `autoCompactEnabled: false`.
- **`CLAUDE_CODE_DISABLE_1M_CONTEXT` set to 1 or true:** it ignores `[1m]`.

## Writing rules

- Only managed keys are written. Everything else is reproduced as it was: key
  order, indentation and number spelling. A small ordered JSON type parses the
  file into ordered members and keeps each number and string as written. A
  file in one consistent style round-trips byte for byte; irregular whitespace
  is normalised.
- A write is one confirmed transaction:
  1. Re-read the file and compare a fingerprint with the previewed one. If it
     changed, stop: "The file changed since this preview."
  2. Copy it to `settings.json.zgate-backup-<yyyyMMdd-HHmmss>` beside it. The
     ten newest backups are kept.
  3. Write a temporary file in the same directory with the original's
     permissions (0600 for a new file), then rename it over.
- "Restore last backup" is itself a confirmed write, and backs up the current
  file first.
- The file is not held in memory: every action re-reads it. The model re-reads
  when the section appears and after every write.

## Where it lives

A section "Claude Code settings file" in Settings → Clients, under the Claude
Code client. No eleventh tab.

- Status: up to date · N changes recommended · no settings file · can't be read.
- One row per managed key: current value, recommended value, whether they
  differ. Checked keys show "set" / "not set".
- A line per id with the window and where it comes from (set here · from
  splash · default), and the token count compaction will run at.
- "Apply recommended…" opens a confirmation sheet listing `key: old → new`,
  the file path and the backup name.
- "Restore last backup…" (confirmation). "Reveal in Finder".
- A disclosure "Recommended values" edits the ids, the local id switch, the
  default window, a window per id, and the percentage.
- A disclosure "Local model id" shows the `local` routing rule and offers to
  point it at the active splash profile when it differs.

## Local model id

Claude Code needs an id of its own for the local model so that it can have
its own window.

- ZGate seeds one exact-match rule: `local` → the active splash profile's
  model at the splash vendor, backup `GLM-5.3-Flash` on the relay, enabled.
  Nobody sends `local` unless Claude Code is told to, so the rule changes no
  existing route.
- Seeded once, gated by a `localRuleSeeded` marker (the pattern of migrations
  10 and 11): a user who deletes the row keeps it deleted.
- A session goes local with `/model local` or `claude --model local`.

## Data model

- `AppConfig.claudeSetup: ClaudeSetupSettings?` and `AppConfig.localRuleSeeded: Bool`
  (optional-tolerant; encoded only when changed from the defaults).
- `ClaudeSetupSettings`: `opusID`, `sonnetID`, `haikuID`, `localIDEnabled`,
  `defaultContextWindow`, `compactPercent`, `contextWindows`.
- Migration 13 seeds the `local` rule.
- Code: `OrderedJSON.swift`; `ClaudeSetup.swift` (recommendation, planner,
  file store); `ClaudeSetupReviewer.swift`, `ClaudeSetupModel.swift`;
  `ClaudeSetupSection.swift`; `ClaudeSetupSettings.swift`.

## Errors

| Situation | Behaviour |
|---|---|
| File missing | State "no settings file". Apply creates it with the managed keys, mode 0600, after confirmation |
| Invalid JSON | Never written. State "can't be read", with the parse error's position |
| Changed since preview | No write; the diff is rebuilt and shown again |
| Permission or I/O failure | Error line in the section; the file is left as it was |
| Backup missing | "Restore" disabled with the reason |

## Testing

105 tests in 8 suites, written first: ordered JSON (round-trip, edits,
invalid input), recommendation (window follows the route, the suffix follows
the window, the key drops the suffix, the threshold, the cap follows the
local model), planner (every managed key, rename and copy, the cap kept when
lower and set when higher or missing, a file already on the suffix), file store
(backup, permissions, refusal on change, idempotence, restore, pruning),
reviewer (states, rows, what is checked and never written), migration 13,
config round-trip.

The section itself has no unit test. It was verified by driving the real app
through accessibility.

## Verification on this machine

1. Dry run on a scratch copy of the real file: the diff lists exactly the
   expected keys and nothing else. Done on 2026-11-23 (first apply) and
   2026-11-24 (the `[1m]` correction and the cap: four lines).
2. Claude Code against the stub with the applied file: the tiers compact
   above 686,000 and not below; `local` above 169,500.
3. Applied to the real file through the section's confirmation.
4. Routes probed through ZGate: `opus` and `sonnet` answer `GLM-5.4`, `haiku`
   answers `GLM-5.3-Flash`, `local` answers the qwen model.

## Deferred, recorded

- The popover banner (orange when the file differs) and the tab selection it
  needs. The section in Settings shows the same status.
- "Copy recommended block" to the clipboard.
- A per-key writer in the section. Hand configuration is by editing the
  recommended values, or the file itself.
- "Verify routes" probe button. Detecting project or managed overrides.
- Class rules before the label match in `RoutingSnapshot`: with the aliases, a
  request for `opus` takes the plain row by its label, so the qwen levers and
  the timed twins do not catch it.

## Risks

- Claude Code rewrites the file itself. Handled by re-reading before every
  write and the fingerprint check.
- These are behaviours of one Claude Code version. The section names the
  version they were measured on.
- A project-level `env` can override the user-level one. Stated in the
  section; not detected.
- A 686,000-token context costs about 2.8 times a 242,144-token one per call
  under the owner's cost rule. That is the owner's requirement 1; the
  percentage is one value.
