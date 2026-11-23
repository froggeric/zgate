# 2026-11-23 — A new model name fell to the catch-all, and would have been renamed upstream

## What happened

z.ai launched GLM-5.4. `settings.json` was switched to `glm-5.4[1m]` for
opus and sonnet, and ZGate's class rules for opus, sonnet and auto were
pointed at `GLM-5.4` and enabled. Every surface agreed that the main
thread ran GLM-5.4. It did not: a probe with the exact wire id returned
`"model":"GLM-5.3-Flash"`. Every "opus" request was answered by the flash
model through the catch-all rule, for an unknown number of hours, with
HTTP 200 and no warning.

## Why

There are two hard-coded gates between a request and the upstream model,
and a new main-model name was missing from both.

**Gate 1 — which rule.** `ModelClass.classify`
(`RouterExtensions.swift`) is a hard-coded pattern list: `flash` → haiku,
`opus`/`fable` → opus, `sonnet` → sonnet, the `glm-5.3` prefix → opus.
`glm-5.4[1m]` matches none of them, so it classified as `nil`. Class
rules only match a known class, so the three enabled GLM-5.4 rules were
skipped and the terminal catch-all rule answered.

**Gate 2 — what name goes upstream.** `RelayTarget.wireBody`, the relay
face's body builder, always passes the chosen target through
`RelayTarget.canonicalModel`, and that function rewrites any `glm-*` name
it does not recognise to `GLM-5.3` (unknown non-GLM names go to flash).
With gate 1 fixed alone, the opus rule would have matched and the request
would still have left as GLM-5.3 while every surface reported 5.4.

A third list, `glmFamily`, feeds the exact-name lookup in
`canonicalModel`. The fix (`0ce9b3b`) adds `glm-5.4` to all three, with
tests on classify, on class-rule routing and on canonicalization.

The mapping table was never the problem. User edits in the app cannot
reach either gate.

## Why nothing showed it

Three places report the *requested* id, never the model that answered:

1. `settings.json` (`ANTHROPIC_DEFAULT_OPUS_MODEL` / `..._SONNET_MODEL`)
2. ZGate's mapping table
3. the harness line "You are powered by the model glm-5.4[1m]"

## The ground truth that settled it

A live probe with the wire id, reading `"model"` from the response body:

```bash
curl -s 127.0.0.1:8787/v1/messages -H 'x-api-key: probe' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"glm-5.4[1m]","max_tokens":8,"messages":[{"role":"user","content":"x"}]}'
```

Before the fix: `GLM-5.3-Flash`. After it, swapped in: `GLM-5.4`.
`glm-5.3-flash[1m]` → `GLM-5.3-Flash`; unknown names → `GLM-5.3-Flash`.

Correction, same day: Claude Code strips `[1m]` before sending (measured
on 2.1.323 against a local stub), so the ids that reached ZGate were
`glm-5.4` and `glm-5.3-flash`. Both forms classified the same way — as
nothing — so the diagnosis stands. A probe should send the bare id.

Vision needed the same discipline. GLM-5.4 is the first main model with
native image input, and three probes gave three different levels of
confidence:

| Probe | Result | What it proves |
|---|---|---|
| 1×1 px PNG | the model described a "padlock" that was not there | the image block is accepted; nothing more |
| 64×64 four-colour quadrants | correct on GLM-5.4 and Flash | image input works end to end |
| 1024×768 rendered report (table, bar chart, 10 px footnote) | 5 of 5 on both, 1,145 input tokens | screenshot-grade reading |

## Rules

1. **A model migration is live when a probe says so, not when config says
   so.** After any model-name change, ZGate upgrade or mapping edit, send
   the exact wire id and compare `"model"` with the expected canonical
   name.
2. **Unknown names degrade silently.** `classify` returns `nil`, the
   catch-all answers 200, and nothing records that a class rule was
   skipped. A visible fall-through in the traffic row would have surfaced
   this in minutes.
3. **A new main-model name lives in three places.** `classify`,
   `canonicalModel` and `glmFamily`; fixing only the first hides the
   problem instead of solving it.
4. **Mind the order.** `flash` is matched before the version prefixes, so
   a future `glm-5.4-flash` classifies as haiku, and `canonicalModel`
   sends it to `GLM-5.3-Flash`.
5. **Probe the failure path, not only the happy one.** On launch day
   GLM-5.4 answered `[1305] The service may be temporarily overloaded` on
   3 of 6 consecutive probes (HTTP 529). The opus and sonnet rules had no
   backup target, so nothing absorbed it. Whether a 1305 triggers the
   backup-target failover is untested.
6. **A tiny image proves nothing.** A 1×1 probe produced a confident
   wrong answer with HTTP 200. Verify vision with an image whose content
   you know: structure first, then text.

## Open follow-ups

- Make main-model classification generic or data-driven, so a launch is
  a config change rather than a three-file patch. Partly done the same
  day: any `glm-` name without "flash" is now opus-class
  (`RouterExtensions.swift`), verified live with the not-yet-released
  `glm-5.5[1m]`. `canonicalModel` and `glmFamily` are still enumerated;
  they only matter when a rule carries no target model.
- Surface catch-all fall-through for names that look like a known family.
- Add a `GLM-5.3` backup target to the opus and sonnet rules and test the
  1305 path.
- The dev build swapped in on 2026-11-23 carries the fix but is still
  numbered 2.11 (3), identical to the shipped release. Bump before the
  next release.
- The full `ZGateTests` target is green serially (812 tests, 58 suites,
  `-parallel-testing-enabled NO`) but flaky under parallel execution:
  `RouterTests.proxyServerAdvancesToNextFreePortWhenConfiguredPortTaken`
  (needs the port after two blockers to stay free while 57 suites bind
  ports), and `OffPeakTargetTests`
  `dataPlaneTransportFailureAnswers502AndSettles` and
  `dataPlaneNon2xxIsDrainedAndAnsweredWithUpstreamShape`. All three pass
  alone. Not checked whether `main` shows the same parallel failures.
