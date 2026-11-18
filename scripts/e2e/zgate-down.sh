#!/bin/bash
# ZGate E2E teardown (Task 10): stop the app, restore the live Application
# Support directory the up script moved aside. Splash is NOT touched here —
# the orchestrator stops what it started.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ZGATE_E2E_ROOT:-${TMPDIR%/}/zgate-e2e}"
APP_SUPPORT="$HOME/Library/Application Support/ZGate"
MARKER="$ROOT/.zgate-e2e-owns-appsupport"

if [ -f "$ROOT/app.pid" ]; then
    pid="$(cat "$ROOT/app.pid")"
    if ps -p "$pid" -o command= 2>/dev/null | grep -q "ZGate.app/Contents/MacOS/ZGate"; then
        kill "$pid"
    fi
    rm -f "$ROOT/app.pid"
fi

if [ -f "$MARKER" ]; then
    rm -rf "$APP_SUPPORT"
    if [ -d "$ROOT/appsupport-live" ]; then
        mv "$ROOT/appsupport-live" "$APP_SUPPORT"
    fi
    rm -f "$MARKER"
    echo "live Application Support restored"
else
    echo "note: E2E did not own $APP_SUPPORT (no marker); nothing restored"
fi
