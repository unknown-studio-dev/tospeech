#!/usr/bin/env bash
# Build what users download: a DMG holding ToSpeech.app and an Applications shortcut.
# They drag the app across and launch it from Applications; nothing runs from Downloads.
# With notarization credentials the DMG is notarized and stapled; without them it is
# Developer ID signed only and Gatekeeper will block it on other Macs.
#   env: APP DEV_ID VERSION [TEAM_ID NOTARY_PROFILE | APPLE_ID APP_PW]
set -euo pipefail
: "${APP:?}" "${DEV_ID:?}" "${VERSION:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dmg="$(dirname "$APP")/ToSpeech-$VERSION.dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$APP" "$stage/ToSpeech.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "ToSpeech" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
codesign --force --timestamp -s "$DEV_ID" "$dmg"
if [ -n "${NOTARY_PROFILE:-}" ] || { [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PW:-}" ]; }; then
  "$here/notarize.sh" "$dmg"
else
  echo "⚠ NOT notarized (set NOTARY_PROFILE=… or APPLE_ID=… APP_PW=…); Gatekeeper will block this DMG on other Macs."
fi
spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | tail -2 || true
echo "▶ DMG: $dmg"
