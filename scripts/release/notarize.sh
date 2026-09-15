#!/usr/bin/env bash
# Submit a signed app or DMG to Apple notarization and staple the ticket.
#   usage: notarize.sh <path>   env: TEAM_ID + (NOTARY_PROFILE | APPLE_ID APP_PW)
set -euo pipefail
target="${1:?path to .app or .dmg}"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PW:-}" ]; then
  auth=(--apple-id "$APPLE_ID" --team-id "${TEAM_ID:?}" --password "$APP_PW")
else
  echo "✗ set NOTARY_PROFILE=<profile>  (or  APPLE_ID=<id> APP_PW=<app-specific-password>)" >&2; exit 1
fi
submission="$target"
if [ -d "$target" ]; then
  submission="${target%.app}.zip"
  echo "▶ Zipping for notarization…"
  /usr/bin/ditto -c -k --keepParent "$target" "$submission"
fi
xcrun notarytool submit "$submission" "${auth[@]}" --wait
[ "$submission" = "$target" ] || rm -f "$submission"
echo "▶ Stapling…"
xcrun stapler staple "$target"
xcrun stapler validate "$target"
echo "▶ Notarized + stapled: $target"
