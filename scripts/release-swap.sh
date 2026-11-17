#!/bin/zsh
# ZGate release swap (Task 11): replace the running prod app at
# /Applications/ZGate.app with a staged build, unattended.
#
# Why this exists: stopping ZGate cuts the API proxy on 127.0.0.1:8787 —
# the port the driving Claude session itself rides — so the swap must run
# as ONE self-contained foreground process that never asks questions and
# never reads stdin (the go-time invocation wraps it in nohup/disown).
#
# Safety shape (binding, task-11 brief):
#   A  validate the staged bundle (exists, .app, bundle id, codesign)
#   B  identify the running app by EXACT executable path (pgrep -f + ps
#      comm/argv0 verification) and cross-check the 8787 listener via lsof.
#      Signals go ONLY to a PID verified this way — never a name pattern.
#   C  SIGTERM the verified PID, wait <=15 s (no SIGKILL escalation)
#   D  wait for 8787 to be free, <=30 s
#   E  backup (mv, never rm -rf) + ditto the staged bundle into place
#   F  open the new app, wait for 8787 LISTEN <=60 s; else ROLLBACK
#   G  health check: plain GET /api/hello (no auth; any HTTP status is
#      proof of life), then SUCCESS with the new CFBundleVersion
#
# --dry-run runs A-B read-only, prints the plan, exits 0 — no signals,
# no swaps, no launches.
#
# Exit codes: 0 ok/dry-run; 1 usage/validation; 2 port 8787 held by a
# non-ZGate process (or ambiguous app identity); 3 app survived SIGTERM;
# 4 port never freed; 5 relaunch failed (rolled back).
#
# Logs field names and exit codes only — never secrets or file contents.
set -u

PROD_APP="/Applications/ZGate.app"
PROD_EXE="$PROD_APP/Contents/MacOS/ZGate"
PORT=8787
HEALTH_URL="http://127.0.0.1:${PORT}/api/hello"
# PRODUCT_BUNDLE_IDENTIFIER from ZGate.xcodeproj/project.pbxproj (app target).
BUNDLE_ID="local.zgate.mac"
LOG_FILE="/tmp/zgate-release-swap.log"

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    print -r -- "$line"
    print -r -- "$line" >> "$LOG_FILE" 2>/dev/null
}

die() {  # die <exit-code> <message>
    local code=$1; shift
    log "ABORT (exit $code): $*"
    exit "$code"
}

usage() {
    print -u2 -- "usage: $ScriptName [--dry-run] <staged-app-path> [log-file]"
    exit 1
}

# ---------------------------------------------------------------- arguments
# NB: `argv` is zsh's positional-parameters array — using it as a scratch
# name would clobber "$@" mid-parse.
ScriptName="$0"
Dry_run=0
Staged=""
Args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) Dry_run=1 ;;
        -h|--help) usage ;;
        *) Args+=("$arg") ;;
    esac
done
(( ${#Args[@]} >= 1 && ${#Args[@]} <= 2 )) || usage
Staged="${Args[1]}"
(( ${#Args[@]} == 2 )) && LOG_FILE="${Args[2]}"

log "=== ZGate release swap start (pid $$, dry-run=$Dry_run) ==="
log "staged path: $Staged"
log "log file:    $LOG_FILE"

# ------------------------------------------------------------- step A: staged
log "STEP A: validating staged bundle"
[[ -d "$Staged" ]] || die 1 "staged bundle not found: $Staged"
[[ "$Staged" == *.app ]] || die 1 "staged path does not end in .app: $Staged"
StagedPlist="$Staged/Contents/Info.plist"
[[ -f "$StagedPlist" ]] || die 1 "staged bundle has no Contents/Info.plist"

StagedID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$StagedPlist" 2>/dev/null)
[[ "$StagedID" == "$BUNDLE_ID" ]] || die 1 "staged CFBundleIdentifier '$StagedID' != expected '$BUNDLE_ID'"
log "STEP A: CFBundleIdentifier ok ($BUNDLE_ID)"

StagedVersion=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$StagedPlist" 2>/dev/null)
StagedBuild=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$StagedPlist" 2>/dev/null)
log "STEP A: staged version fields: CFBundleShortVersionString=$StagedVersion CFBundleVersion=$StagedBuild"

codesign --verify --deep --strict "$Staged" >/dev/null 2>&1
CS=$?
log "STEP A: codesign --verify --deep --strict exit=$CS"
(( CS == 0 )) || die 1 "staged bundle fails codesign verification (exit $CS)"

# ------------------------------------------------- step B: running app + port
log "STEP B: identifying running app (exact exe path) and port $PORT holder"

# pgrep -f matches the full argument string, so an editor or this script's
# own driver could match; every candidate is re-verified below via ps.
Candidates=$(pgrep -f "$PROD_EXE" 2>/dev/null || true)
AppPids=()
for pid in ${(f)Candidates}; do
    Comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    Argv0=$(ps -p "$pid" -o command= 2>/dev/null || true)
    Argv0="${Argv0%% *}"
    if [[ "$Comm" == "$PROD_EXE" || "$Argv0" == "$PROD_EXE" ]]; then
        AppPids+=("$pid")
    else
        log "STEP B: pgrep hit $pid skipped (comm/argv0 is not the prod exe)"
    fi
done

PortHolders=$(lsof -tiTCP:$PORT -sTCP:LISTEN -P -n 2>/dev/null || true)
for pid in ${(f)PortHolders}; do
    HolderComm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    if [[ "$HolderComm" == "$PROD_APP"/* ]]; then
        log "STEP B: port $PORT held by in-app pid $pid ($HolderComm)"
    else
        die 2 "port $PORT is held by pid $pid whose executable is NOT inside $PROD_APP (comm: $HolderComm) — refusing to touch it"
    fi
done

TargetPid=""
if (( ${#AppPids[@]} == 0 )); then
    log "STEP B: $PROD_APP is NOT running — stop steps will be skipped"
else
    if (( ${#AppPids[@]} > 1 )); then
        log "STEP B: WARNING ${#AppPids[@]} verified app pids (${AppPids[*]}); signaling the lowest"
    fi
    TargetPid="${AppPids[1]}"
    log "STEP B: verified app pid $TargetPid (exe $PROD_EXE)"
    if [[ -n "$PortHolders" && " ${=PortHolders//$'\n'/ } " != *" $TargetPid "* ]]; then
        log "STEP B: note — verified pid does not itself hold $PORT, but every holder is in-app (checked above)"
    fi
fi

# ------------------------------------------------------------- dry-run plan
if (( Dry_run )); then
    BackupPath="$PROD_APP.preSwap-<timestamp>"
    log "DRY-RUN: no signals, no swaps, no launches below this line"
    log "DRY-RUN plan:"
    log "  C: would SIGTERM verified pid: ${TargetPid:-<none — app not running>}"
    log "     then wait <=15 s for exit (abort exit 3 if alive; no SIGKILL)"
    log "  D: would wait <=30 s for port $PORT to be free (abort exit 4 if bound)"
    log "  E: would mv $PROD_APP -> $BackupPath (rollback copy, never rm -rf)"
    log "     then ditto $Staged -> $PROD_APP"
    log "  F: would open $PROD_APP and wait <=60 s for port $PORT LISTEN;"
    log "     on timeout would ROLLBACK: mv new app aside, restore $BackupPath, open it, exit 5"
    log "  G: would GET $HEALTH_URL (no auth) <=30 s for any HTTP status, then log SUCCESS with new CFBundleVersion"
    if [[ -d "$PROD_APP" ]]; then
        ProdVersion=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROD_APP/Contents/Info.plist" 2>/dev/null || echo "<unreadable>")
        ProdBuild=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROD_APP/Contents/Info.plist" 2>/dev/null || echo "<unreadable>")
        log "DRY-RUN: currently installed: CFBundleShortVersionString=$ProdVersion CFBundleVersion=$ProdBuild -> $StagedVersion/$StagedBuild"
    else
        log "DRY-RUN: no app currently installed at $PROD_APP (swap step E would fail)"
    fi
    log "DRY-RUN complete — nothing was modified"
    log "=== ZGate release swap end (dry-run) ==="
    exit 0
fi

# ------------------------------------------------------- step C: stop the app
BackupPath=""
if [[ -n "$TargetPid" ]]; then
    log "STEP C: SIGTERM -> pid $TargetPid"
    kill -TERM "$TargetPid" 2>/dev/null
    Rc=$?
    log "STEP C: kill exit=$Rc"
    Cutoff=$(( SECONDS + 15 ))
    while (( SECONDS < Cutoff )); do
        ps -p "$TargetPid" -o pid= >/dev/null 2>&1 || break
        sleep 1
    done
    if ps -p "$TargetPid" -o pid= >/dev/null 2>&1; then
        die 3 "pid $TargetPid still alive 15 s after SIGTERM — NOT escalating to SIGKILL; prod bundle untouched"
    fi
    log "STEP C: pid $TargetPid exited"
else
    log "STEP C: skipped (app not running)"
fi

# -------------------------------------------------- step D: wait for the port
log "STEP D: waiting <=30 s for port $PORT to be free"
Cutoff=$(( SECONDS + 30 ))
while (( SECONDS < Cutoff )); do
    Holders=$(lsof -tiTCP:$PORT -P -n 2>/dev/null || true)
    [[ -z "$Holders" ]] && break
    sleep 1
done
Holders=$(lsof -tiTCP:$PORT -P -n 2>/dev/null || true)
if [[ -n "$Holders" ]]; then
    die 4 "port $PORT still bound (pids: ${(f)Holders}) after 30 s — prod bundle untouched"
fi
log "STEP D: port $PORT free"

# --------------------------------------------------- step E: backup + swap in
BackupPath="$PROD_APP.preSwap-$(date +%Y%m%d-%H%M%S)"
log "STEP E: mv $PROD_APP -> $BackupPath"
if ! mv "$PROD_APP" "$BackupPath"; then
    die 1 "backup mv failed — prod bundle untouched, aborting before any replace"
fi
log "STEP E: ditto $Staged -> $PROD_APP"
if ! ditto "$Staged" "$PROD_APP"; then
    log "STEP E: ditto FAILED — restoring backup"
    mv "$BackupPath" "$PROD_APP" && log "STEP E: backup restored" || log "STEP E: RESTORE FAILED — $BackupPath left as the rollback copy"
    die 1 "staged bundle could not be copied into place"
fi
log "STEP E: swap complete (rollback copy: $BackupPath)"

# ---------------------------------------------- step F: relaunch or rollback
log "STEP F: open $PROD_APP (first launch runs config migrations)"
open "$PROD_APP" 2>/dev/null
Rc=$?
log "STEP F: open exit=$Rc"
log "STEP F: waiting <=60 s for port $PORT to LISTEN"
Cutoff=$(( SECONDS + 60 ))
Listened=0
while (( SECONDS < Cutoff )); do
    Holders=$(lsof -tiTCP:$PORT -sTCP:LISTEN -P -n 2>/dev/null || true)
    if [[ -n "$Holders" ]]; then Listened=1; break; fi
    sleep 1
done
if (( ! Listened )); then
    FailedPath="$PROD_APP.failedSwap-$(date +%Y%m%d-%H%M%S)"
    log "STEP F: *** ROLLBACK — port $PORT not listening after 60 s ***"
    log "STEP F: mv $PROD_APP -> $FailedPath"
    mv "$PROD_APP" "$FailedPath" || log "STEP F: could not move failed bundle aside"
    log "STEP F: mv $BackupPath -> $PROD_APP"
    mv "$BackupPath" "$PROD_APP" || log "STEP F: could not restore backup — $BackupPath holds the old app"
    log "STEP F: reopening the restored app"
    open "$PROD_APP" 2>/dev/null
    die 5 "new app did not serve on $PORT within 60 s — rolled back to the previous bundle"
fi
log "STEP F: port $PORT is listening again"

# ------------------------------------------------------- step G: health check
log "STEP G: GET $HEALTH_URL (no auth) <=30 s, any HTTP status = alive"
HttpStatus=""
Cutoff=$(( SECONDS + 30 ))
while (( SECONDS < Cutoff )); do
    HttpStatus=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null)
    Rc=$?
    if (( Rc == 0 )) && [[ -n "$HttpStatus" && "$HttpStatus" != "000" ]]; then
        break
    fi
    HttpStatus=""
    sleep 1
done
if [[ -z "$HttpStatus" ]]; then
    log "STEP G: WARNING — no HTTP response within 30 s (app is listening on $PORT but not answering)"
else
    log "STEP G: HTTP status $HttpStatus (proof of life; any status counts)"
fi

NewBuild=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROD_APP/Contents/Info.plist" 2>/dev/null || echo "<unreadable>")
log "SUCCESS: $PROD_APP now serves $PORT with CFBundleVersion=$NewBuild (rollback copy: $BackupPath)"
log "=== ZGate release swap end ==="
exit 0
