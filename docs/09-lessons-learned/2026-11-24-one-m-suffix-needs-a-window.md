# 2026-11-24 — `[1m]` was blamed for a stale cap

## What happened

The configurator's design of 2026-11-23 recommended the bare aliases
(`opus`, `sonnet`, `haiku`) and the removal of
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`. It stated that `[1m]` on an id Claude
Code does not know "switches proactive compaction off". The owner applied
it. The next morning Claude Code refused to continue at a full context, or
forced a compaction, and fixed it by hand: `opus[1m]`.

## Why

Two measurements were each half of the truth.

1. **The probes never combined `[1m]` with a window.** With `[1m]` and no
   `modelSettings.<id>.autoCompactWindow`, Claude Code skips the compaction
   check for the id. With the window, the check runs: `opus[1m]` and a
   window of 1M compacted at 686,000. The conclusion "`[1m]` switches
   compaction off" was drawn from the first case alone and written into the
   spec, the README and a memory note.
2. **A session keeps the environment it was started with.** The owner's
   session had started while `settings.json` still carried
   `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144`. The configurator removed the
   variable from the file; the running session kept it. A bare id takes that
   variable's value: the window fell to 262,144, compaction was forced at
   169,500 and the session was blocked at 239,000. `[1m]` pins the window to
   1M whatever the variable says, which is why the owner's fix worked.

The bare ids were not wrong for a session started after the change. They
were fragile: any `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in the environment, from
any source, caps them without a sign.

## What replaced it

- Tier ids carry `[1m]` when their window is 1M or more, and every id gets
  its window written out.
- The global cap is recommended at the local model's window instead of
  removed: `[1m]` ids ignore it, and it protects `local` and any id typed by
  hand.

## Rules

1. **Vary every factor before naming a cause.** A probe that changes one
   thing measures one thing. "`[1m]` alone skips the check" became "`[1m]`
   disables compaction" because no run added the window.
2. **Read the other side's code when a behaviour decides a design.** The
   bundle showed the pin (`Math.max(…, 1e6)` for ids with `[1m]`) and the
   gate (the check is skipped when the window source is "auto") in two
   functions. An hour of stub runs had not.
3. **A running session is not the file.** Environment variables are read at
   start. A settings change is verified in a new session, never in the one
   that made the change.
4. **Prefer the mechanism that survives a stale value.** A suffix that pins
   the window beat an absent variable that anything in the environment can
   set.
5. **When the owner's machine contradicts the measurement, the measurement
   is incomplete.** "It looks like `[1m]` is needed" was a correct report
   from the field; the first move is to reproduce it, not to re-explain.
