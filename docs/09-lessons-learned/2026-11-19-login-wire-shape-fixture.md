# 2026-11-19 — A synthetic fixture passed CI while the login could never succeed

## What happened

ZGate 2.8(7)/(8) shipped an in-app OAuth login whose poll parser expected
the access token at the top level of the ready payload
(`data.accessToken`). The real server nests it under the provider key:
`data.zai.access_token` (with top-level `token` and `user`). Every
genuine "ready" answer fell through to "keep polling", so a fresh-install
login hung at "authorizing…" for the 300 s cap and fell back to the
sign-in state — the browser authorization had succeeded. Machines with an
existing store never run the flow, which masked the bug everywhere except
new machines.

## Why the tests did not catch it

`ZaiLoginClientTests.readyBody()` was authored from the reverse-engineering
notes, not from a captured response, and the parser was written to the
same assumption — a **self-consistent synthetic pair**. Parser and fixture
agreed; the suite was green; the wire disagreed. The 2.8(8) origin fix was
live-verified against the *init* leg only ("init → 200"), and the ready
leg — the one carrying credentials — was never exercised against the real
server before shipping.

## The ground truth that settled it

The shipped `ZCode.app` CLI bundle (`zcode.cjs`, minified) contains the
reference parser. Its ready parser reads `e[providerId].access_token`
(`providerId ?? "zai"`), requires top-level `token` + `user.user_id`, and
throws on any non-2xx poll status (ZGate silently retried all non-200s —
including the 400 `invalid_flow` that answers after the 300 s server-side
flow expiry, which produced the identical silent hang for slow
first-browser-logins). Two independent extractions of the minified
functions plus live probes of init/pending/expired settled the shape;
completing a real browser authorization headlessly was impossible (it
needs a human session), so the reference client was the evidence.

## Rules

1. **A wire format is only "verified" when the leg that carries it has
   been observed, not inferred.** "Init live-verified" said nothing about
   the ready payload. When a response cannot be captured, derive fixtures
   from the reference client's parser (the CLI bundle), and say so in the
   fixture's comment.
2. **A parser and its fixture written from the same assumption prove
   nothing.** Pin at least one fixture to an observed shape (or to the
   reference implementation's exact expectations) and label the source.
3. **Silent retry of non-2xx answers converts every protocol mismatch
   into a timeout.** The reference client aborts on non-2xx; diverging
   from it (tolerating 408/429/5xx) is fine, but permanent 4xx must fail
   fast with typed copy — otherwise the user sees "authorizing…" for five
   minutes and a login state, with no diagnostic anywhere.
4. **Fresh-install paths are invisible to machines with warm state.**
   Any flow gated on "no stored credentials" needs a fresh-store test (or
   an E2E on a clean home) before release — the 2.8.8 release notes
   already flagged "fresh-machine E2E of the login flow" as known-open;
   this was exactly that gap.

## Where the fix lives

- `ModelProxy/Signing/ZaiLoginClient.swift` — provider-nested ready
  parsing (`providerKey`), 4xx fail-fast (`invalid_flow` → "Sign-in
  window expired — retry").
- `ModelProxyTests/ZaiLoginClientTests.swift` — fixture corrected to the
  real wire shape; regression tests for the camelCase variant,
  `invalid_flow` fail-fast, and non-transient 4xx abort.
- Same day: `ModelProxy/Models/CredentialStatusModel.swift` — the
  location-less setup gap derived from the snapshot (see
  `f95b9fe`), because a working login then exposed a face bug
  ("renewing forever") on the same fresh machines.
