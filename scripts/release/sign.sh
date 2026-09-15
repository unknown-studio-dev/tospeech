#!/usr/bin/env bash
# Developer ID-sign every embedded Mach-O inside-out (libs → helpers, xeus-helper with
# the Python hardened-runtime exceptions), then seal the app. Re-signs correctly
# regardless of what the Xcode stage-*.sh phases did.
#   env: APP DEV_ID ENT_APP ENT_HELPER ENT_PY
set -euo pipefail
: "${APP:?}" "${DEV_ID:?}" "${ENT_APP:?}" "${ENT_HELPER:?}" "${ENT_PY:?}"
res="$APP/Contents/Resources"
security find-identity -v -p codesigning | grep -qF "$DEV_ID" || { echo "✗ signing identity not found: $DEV_ID" >&2; exit 1; }
# PyInstaller copies Python.framework as plain files; codesign treats any path inside a
# *.framework/ as a bundle and refuses ("bundle format is ambiguous"), so those Mach-O
# files are signed through a temporary copy and moved back.
sign_one() {
  case "$2" in
    *.framework/*)
      tmp="$(mktemp -d)/$(basename "$2")"
      cp -p "$2" "$tmp"
      codesign --force --timestamp --options runtime -s "$DEV_ID" --entitlements "$1" "$tmp"
      mv -f "$tmp" "$2"; rmdir "$(dirname "$tmp")" ;;
    *) codesign --force --timestamp --options runtime -s "$DEV_ID" --entitlements "$1" "$2" ;;
  esac
}
echo "▶ Signing embedded Mach-O (inside-out)…"
if [ -d "$res" ]; then
  while IFS= read -r -d '' f; do echo "   lib  $f"; sign_one "$ENT_HELPER" "$f"; done \
    < <(find "$res" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.abi3.so' \) -print0)
  while IFS= read -r -d '' f; do
    case "$f" in *.dylib|*.so|*.abi3.so) continue ;; esac
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    if [ "$(basename "$f")" = "xeus-helper" ]; then echo "   py   $f"; sign_one "$ENT_PY" "$f"
    else echo "   exec $f"; sign_one "$ENT_HELPER" "$f"; fi
  done < <(find "$res" -type f -print0)
fi
echo "▶ Sealing app…"
sign_one "$ENT_APP" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true
echo "▶ Signed: $APP"
