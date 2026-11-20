# Shared settings for the ModelProxy E2E harness. Sourced by the other scripts; see README.md.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$E2E_DIR" rev-parse --show-toplevel)"

# Everything the harness creates lives here (builds, Claude Code home, workspace, logs of runs).
E2E_ROOT="${MP_E2E_ROOT:-${TMPDIR%/}/modelproxy-e2e}"
# Mapped client port and a second client whose unmapped models pass through to Anthropic.
E2E_PORT="${MP_E2E_PORT:-19090}"
E2E_PASSTHROUGH_PORT="${MP_E2E_PASSTHROUGH_PORT:-19092}"
E2E_BUNDLE_ID="local.zgate.mac.e2e"
# The E2E build's own container. The app is launched with
# ZGATE_APP_SUPPORT_DIR=$E2E_APP_SUPPORT (AppPaths' highest-priority redirect)
# so the staged build never reads or writes the live
# ~/Library/Application Support/ZGate — required since the non-sandboxed
# installed build and the E2E build would otherwise share one config.json
# (pre-2026-11-20 the rig wrote the live directory behind a marker file and
# could not run at all next to a live install).
E2E_APP_SUPPORT="${MP_E2E_APP_SUPPORT:-$E2E_ROOT/app-support}"
E2E_MARKER="$E2E_APP_SUPPORT/.modelproxy-e2e"
# Empty credential-store base handed to the app via the staged config's
# credentialStoreBase: the relay vendor's signing chain then fails cold
# locally (no ~/.zcode read, no zcode.z.ai traffic) — the dead-signing
# scenario's precondition.
E2E_CREDENTIAL_STORE="$E2E_ROOT/credential-store"
E2E_PID_FILE="$E2E_ROOT/app.pid"
E2E_MODEL="${MP_E2E_MODEL:-deepseek-flash}"
# Off-peak async surface in the staged config: 1 = enabled (origin pointed
# at a dead local port — the control-plane-failure ladder), 0 = disabled
# (default-OFF answers). Scenario families for each state; see gen_config.py.
E2E_ASYNC_OFFPEAK="${E2E_ASYNC_OFFPEAK:-1}"

e2e_log_file() {
    echo "$E2E_APP_SUPPORT/logs/modelproxy-$(date +%F).log"
}

# Reads a value from the environment first, then from $REPO_ROOT/.env (NAME=value lines).
e2e_secret() {
    local name="$1" value="${!1:-}"
    if [ -z "$value" ] && [ -f "$REPO_ROOT/.env" ]; then
        value="$(grep -E "^${name}=" "$REPO_ROOT/.env" | tail -1 | cut -d= -f2-)"
    fi
    # Legacy .env layout ("KEY：…" / "Engine ID：…", full-width colons) holds the Google credentials.
    if [ -z "$value" ] && [ -f "$REPO_ROOT/.env" ]; then
        case "$name" in
            GOOGLE_SEARCH_API_KEY) value="$(grep -E "^KEY[：:]" "$REPO_ROOT/.env" | sed -E 's/^KEY[：:] *//')" ;;
            GOOGLE_SEARCH_ENGINE_ID) value="$(grep -E "^Engine ID[：:]" "$REPO_ROOT/.env" | sed -E 's/^Engine ID[：:] *//')" ;;
        esac
    fi
    printf '%s' "$value" | tr -d '\r'
}

e2e_die() {
    echo "e2e: $*" >&2
    exit 1
}
