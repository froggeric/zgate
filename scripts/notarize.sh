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
