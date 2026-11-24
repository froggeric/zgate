# 2026-11-24 — the Dock icon stayed after Settings closed

## What happened

2.12 (1) switched ZGate to the regular activation policy while the
Settings window was open and back to accessory when it closed. The check
after the release found the Dock icon still there with no window left.

## How it was found

- **Under a trace, on an isolated copy of the app.** `scripts/e2e/build.sh`
  gives a copy with its own bundle id, data directory and ports, so the
  running proxy was never interrupted. The copy was renamed (executable,
  bundle and display name) so System Events could tell it from the
  installed app. The trace sat behind an environment variable and was
  discarded before the fix was written.
- **What the trace showed.** Around the close, the policy read `.accessory`
  before the presenter's handler ran, and no call from the app had set it
  (a hook on the setter logged every caller). In three sessions of about
  twenty it read `.regular` again right after, and the icon stayed.
- **Three candidates, each excluded by one replay.** The confirmation
  sheet, the About tab's update check and the accessibility press on the
  close button were all in the failing session. The plain open-then-close
  flow reproduced the failure without any of them.
- **It is a race.** It happened three times that day, in the installed app
  and in two replays, and in none of the sixteen replays that followed.

## Why

Two writers, one value. The framework changes the activation policy around
the close of an app's last window. The presenter wrote once, at the close.
When the framework's second change came after that write, the write was
overwritten. The presenter's code did what it said; what it said was not
enough. A notification reports that the window closed, not that the state
held.

## What replaced it

`SettingsPresenter` restores the policy at the close and checks it again at
0.25 s, 0.75 s and 2 s. A check that finds another policy writes the resting
one. A check that comes due while Settings is open again does nothing.

The fix was checked on the isolated copy with a hook that switched the
policy to regular 0.3 s after the close: back to accessory at 0.78 s, on
two runs.

## Rules

1. **A write is not a state.** When the framework or the system writes the
   same value, read it back on a schedule that outlasts the other writer.
2. **Trace before fixing.** The first hypothesis, an observer bound to a
   window that SwiftUI had replaced, was wrong: the close was seen and the
   handler ran.
3. **Clear the candidates one replay at a time.** Everything unusual in the
   failing session was innocent.
4. **A race that stops reproducing is not gone.** Sixteen clean replays do
   not clear the code. Verify the fix by injecting the fault.
5. **A rare interface bug is cheap on an isolated copy.** Separate bundle
   id, data directory, ports and process name, and a log behind an
   environment variable.

Related: `E001-menubarextra-settings-activation.md` (why the policy is
switched at all).
