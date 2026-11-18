#!/bin/bash
# ZGate E2E bring-up (Task 10): isolated app copy + the default rule table.
#
# Unlike the upstream harness (DeepSeek vendor, port 19090), this wires the
# ZGate default routing matrix — relay + splash — on the spec's port 8787 and
# seeds the signing chain from the scratch store's biz session, so real
# `claude` traffic rides the SIGNED relay path.
#
# The app has no config-dir override, so the E2E OWNS ~/Library/Application
# Support/ZGate for its duration: the live directory is moved aside
# (not deleted) and zgate-down.sh restores it. Refuses to start if a previous
# run's swap is still in place.
#
# Splash (127.0.0.1:8000) is NOT managed here — start/stop it around the
# AC2 halves per docs/e2e-checklist.md.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$E2E_DIR" rev-parse --show-toplevel)"
ROOT="${ZGATE_E2E_ROOT:-${TMPDIR%/}/zgate-e2e}"
APP_SUPPORT="$HOME/Library/Application Support/ZGate"
SCRATCH_CACHE="$HOME/.zcode-scratch-v3/biz-session.cache"
PORT="${ZGATE_E2E_PORT:-8787}"
CODEX_PORT="${ZGATE_E2E_CODEX_PORT:-8789}"   # 8788 belongs to zbridge — never touched
MARKER="$ROOT/.zgate-e2e-owns-appsupport"

die() { echo "zgate-e2e: $*" >&2; exit 1; }

app="$(cat "${TMPDIR%/}/modelproxy-e2e/last-app-path" 2>/dev/null || true)"
[ -n "$app" ] && [ -d "$app" ] || die "no E2E build; run scripts/e2e/build.sh first"
[ "$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)" = "local.zgate.mac.e2e" ] \
    || die "$app is not an E2E build"

lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "port $PORT already in use"
lsof -nP -iTCP:"$CODEX_PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "port $CODEX_PORT already in use"
[ -f "$MARKER" ] && die "previous run still owns $APP_SUPPORT; run zgate-down.sh first"
[ -f "$SCRATCH_CACHE" ] || die "no scratch biz session at $SCRATCH_CACHE (seed source)"

mkdir -p "$ROOT"

# Swap the live Application Support aside; everything in it survives verbatim.
if [ -d "$APP_SUPPORT" ]; then
    mv "$APP_SUPPORT" "$ROOT/appsupport-live"
fi
mkdir -p "$APP_SUPPORT"
touch "$MARKER"

# Default rule table: the exact AppConfig.makeZGateDefaultRouting matrix
# (owner ruling 2026-11-16, correcting spec §2: sonnet → relay flash, haiku →
# splash q8) with the Claude Code client on the E2E port and file logging at
# debug so the request log the assertions read is on disk.
python3 - "$APP_SUPPORT/config.json" "$PORT" "$CODEX_PORT" <<'PY'
import json, sys, uuid

out, port, codex_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
relay, splash = str(uuid.uuid4()), str(uuid.uuid4())
config = {
    "vendors": [
        {
            "id": relay, "name": "zcode relay",
            "baseURL": "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            "apiKey": "", "connectTimeoutSeconds": 10, "readTimeoutSeconds": 300,
            "supportsThinkingBlocks": True, "supportsAnthropicCountTokens": False,
            "vendorKind": "relay",
        },
        {
            "id": splash, "name": "splash (local)",
            "baseURL": "http://127.0.0.1:8000", "apiKey": "",
            "replayPolicy": "portableOnly",
        },
    ],
    "clients": [
        {
            "id": str(uuid.uuid4()), "clientName": "Claude Code", "port": port,
            "defaultUpstream": "https://api.anthropic.com", "unmappedPolicy": "passthrough",
        },
        {
            "id": str(uuid.uuid4()), "clientName": "Codex", "port": codex_port,
            "defaultUpstream": "https://api.openai.com", "unmappedPolicy": "passthrough",
        },
    ],
    "modelMappings": [
        {"id": str(uuid.uuid4()), "sourceModel": "auto", "targetModel": "GLM-5.3",
         "targetVendorID": relay, "matchClass": "auto", "isEnabled": True},
        {"id": str(uuid.uuid4()), "sourceModel": "haiku", "targetModel": "local/qwen3.8-27b-q8",
         "targetVendorID": splash, "backupTargetModel": "GLM-5.3-Flash",
         "backupTargetVendorID": relay, "matchClass": "haiku", "isEnabled": True},
        {"id": str(uuid.uuid4()), "sourceModel": "sonnet", "targetModel": "GLM-5.3-Flash",
         "targetVendorID": relay, "matchClass": "sonnet", "isEnabled": True},
        {"id": str(uuid.uuid4()), "sourceModel": "opus (peak hours)", "targetModel": "GLM-5.3-Flash",
         "targetVendorID": relay, "matchClass": "opus", "isEnabled": False,
         "conditions": [{"type": "timeWindow", "days": "weekdays", "from": "07:00",
                          "to": "11:00", "tz": "Europe/Paris"}]},
        {"id": str(uuid.uuid4()), "sourceModel": "opus", "targetModel": "GLM-5.3",
         "targetVendorID": relay, "matchClass": "opus", "isEnabled": True},
        {"id": str(uuid.uuid4()), "sourceModel": "fallback", "targetModel": "GLM-5.3-Flash",
         "targetVendorID": relay, "catchAll": True, "isEnabled": True},
    ],
    # All five keys: DebugConfig's synthesized decode requires cleanupAfterDays
    # and compressAfterDays — a partial object throws, and ConfigStore's `try?`
    # silently swaps in defaults (file logging OFF).
    "debug": {"isEnabled": True, "minimumLogLevel": "debug",
               "autoCleanupEnabled": False, "cleanupAfterDays": 7,
               "compressAfterDays": 3},
}
with open(out, "w") as f:
    json.dump(config, f, indent=2, sort_keys=True)
PY

# Signing chain: the scratch store's OAuth token is expired (1 h TTL), but the
# biz session is 180-day valid — seed ZGate's cache so the chain rebuilds
# without z/login. Copied, never printed.
install -m 600 "$SCRATCH_CACHE" "$APP_SUPPORT/biz-session.cache"

open -n "$app"
pid=""
for _ in $(seq 1 20); do
    pid="$(pgrep -f "$app/Contents/MacOS/ZGate" | head -1 || true)"
    [ -n "$pid" ] && break
    sleep 0.5
done
[ -n "$pid" ] || die "app did not start"
echo "$pid" > "$ROOT/app.pid"

# Listeners start at app launch (ModelProxyApp init start). The click below
# opens the popover once anyway — exercising the idempotent popover start
# path (start() no-ops while running) the way a real user session would.
sleep 2
swift "$E2E_DIR/click_status_item.swift" "$pid" >/dev/null \
    || die "could not click the status item (Accessibility for the terminal?)"

for _ in $(seq 1 30); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "ZGate E2E up: pid $pid, Claude Code port $PORT (Codex $CODEX_PORT)"
        echo "log: $APP_SUPPORT/logs/modelproxy-$(date +%F).log"
        exit 0
    fi
    sleep 0.5
done
die "proxy did not start listening on $PORT"
