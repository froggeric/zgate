#!/bin/zsh
# ZGate notarization (2026-11-18): submit a Developer ID-signed build to
# Apple's notary service and staple the ticket. Runs AFTER the Release
# build; the release-swap script then swaps the stapled bundle in.
#
# One-time setup (owner):
#   xcrun notarytool store-credentials zgate-notary \
#     --apple-id frederic@guigand.com --team-id 46BZ85ALNS \
#     --password <app-specific password from appleid.apple.com>
#
# Usage: notarize.sh <path-to-ZGate.app>
# notarytool takes a zip/pkg/dmg, so the app is zipped for submission and
# the STAPLE lands on the .app itself (stapled before distribution zips).
#
# Exit codes: 0 notarized + stapled + spctl-verified; 1 usage; 2 submit
# failed; 3 staple failed; 4 Gatekeeper assessment failed.
#
# Prints statuses and Apple request ids only — never credentials.
set -u

PROFILE="zgate-notary"
APP="${1:-}"

[[ -d "$APP" && "$APP" == *.app ]] || {
    print -u2 "usage: notarize.sh <path-to-ZGate.app>"; exit 1
}

# Deterministic Developer ID re-sign (2026-11-18): xcodebuild's Manual-style
# signing of this project leaves the app without a secure timestamp and with
# a get-task-allow entitlement — both notarization blockers. Sign nested
# code first (innermost-out), then the bundle, with the project's (empty)
# entitlements file, hardened runtime, and a secure timestamp.
# SHA-1 of the Developer ID Application cert (from `security
# find-identity`) — ASCII hash avoids encoding trouble with accents.
IDENTITY="432C0A2711F592AE130323315704C5D5071A8C07"
ENTITLEMENTS="$(dirname "$0")/../ModelProxy/ModelProxy.entitlements"
find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \) | while read -r nested; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested" >/dev/null 2>&1 || true
done
if ! codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP"; then
    print -u2 "notarize: re-sign failed"; exit 2
fi
codesign --verify --deep --strict "$APP" || { print -u2 "notarize: re-sign failed verify"; exit 2; }

SUBMIT_ZIP="$(mktemp -d)/ZGate-notary-submit.zip"
if ! ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"; then
    print -u2 "notarize: could not zip for submission"; exit 2
fi

print "notarize: submitting $(basename "$APP") (profile $PROFILE)"
if ! xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait; then
    print -u2 "notarize: submission failed"; exit 2
fi

print "notarize: stapling ticket onto the app"
if ! xcrun stapler staple "$APP"; then
    print -u2 "notarize: staple failed"; exit 3
fi

print "notarize: Gatekeeper assessment"
if ! spctl --assess --type execute -vv "$APP"; then
    print -u2 "notarize: spctl assessment FAILED"; exit 4
fi

print "notarize: OK — signed, notarized, stapled, Gatekeeper-approved"
exit 0
