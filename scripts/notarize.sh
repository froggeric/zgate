#!/bin/zsh
# ZGate notarization (2026-11-18): submit a Developer ID-signed, stapled
# build to Apple's notary service. Runs AFTER the Release build; the
# release-swap script then swaps the stapled bundle in.
#
# One-time setup (owner, already done or to do once):
#   xcrun notarytool store-credentials zgate-notary \
#     --apple-id frederic@guigand.com --team-id 46BZ85ALNS \
#     --password <app-specific password from appleid.apple.com>
#
# Usage: notarize.sh <path-to-ZGate.app>
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

print "notarize: submitting $(basename "$APP") (profile $PROFILE)"
if ! xcrun notarytool submit "$APP" --keychain-profile "$PROFILE" --wait; then
    print -u2 "notarize: submission failed"; exit 2
fi

print "notarize: stapling"
if ! xcrun stapler staple "$APP"; then
    print -u2 "notarize: staple failed"; exit 3
fi

print "notarize: Gatekeeper assessment"
if ! spctl --assess --type execute -vv "$APP"; then
    print -u2 "notarize: spctl assessment FAILED"; exit 4
fi

print "notarize: OK — signed, notarized, stapled, Gatekeeper-approved"
exit 0
