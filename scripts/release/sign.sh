#!/usr/bin/env bash
# Developer ID-sign every embedded Mach-O inside-out (libs → helpers, then nested
# frameworks, then the app seal). Every signature carries a secure timestamp —
# Apple notarization rejects timestamp-less nested framework signatures.
#   env: APP DEV_ID ENT_APP ENT_HELPER ENT_PY
set -euo pipefail
: "${APP:?}" "${DEV_ID:?}" "${ENT_APP:?}" "${ENT_HELPER:?}" "${ENT_PY:?}"
res="$APP/Contents/Resources"
security find-identity -v -p codesigning | grep -qF "$DEV_ID" || { echo "✗ signing identity not found: $DEV_ID" >&2; exit 1; }
# codesign treats any path inside a *.framework/ as a bundle and refuses standalone
# Mach-O signing ("bundle format is ambiguous"), so such files are signed through a
# temporary copy and moved back.
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
    case "$(basename "$f")" in
      xeus-helper|yt-dlp_macos) echo "   py   $f"; sign_one "$ENT_PY" "$f" ;;   # PyInstaller: needs library-validation off
      *) echo "   exec $f"; sign_one "$ENT_HELPER" "$f" ;;
    esac
  done < <(find "$res" -type f -print0)
fi
# Re-signing changed the tool bytes; the app refuses tools whose hash differs from this
# manifest (BundledImportToolchain), so pin the signed hashes (same format as stage-toolchain.sh).
tools="$res/Tools"
if [ -d "$tools" ]; then
  hash() { shasum -a 256 "$1" | awk '{print $1}'; }
  printf '{\n  "yt-dlp": "%s",\n  "ffmpeg": "%s",\n  "ffprobe": "%s",\n  "qjs": "%s"\n}\n' \
    "$(hash "$tools/yt-dlp/yt-dlp_macos")" "$(hash "$tools/ffmpeg")" "$(hash "$tools/ffprobe")" "$(hash "$tools/qjs")" \
    > "$res/Toolchain.runtime.json"
  echo "▶ Toolchain.runtime.json re-pinned to signed tools"
fi
# Frameworks embedded by SPM/Xcode (e.g. onnxruntime.framework) carry the vendor's
# signature — often without a secure timestamp, which notarization rejects. Re-sign
# each nested framework root so the seal covers timestamped signatures throughout.
fws="$APP/Contents/Frameworks"
if [ -d "$fws" ]; then
  while IFS= read -r -d '' fw; do echo "   fw   $fw"; sign_one "$ENT_HELPER" "$fw"; done \
    < <(find "$fws" -maxdepth 1 -type d -name '*.framework' -print0)
fi
echo "▶ Sealing app…"
sign_one "$ENT_APP" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true
echo "▶ Signed: $APP"
