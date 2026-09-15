#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/scripts/toolchain/verify-toolchain.sh"

: "${TARGET_BUILD_DIR:?Xcode must supply TARGET_BUILD_DIR}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode must supply resource path}"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
TOOLS="$DEST/Tools"
LICENSES="$DEST/Licenses"
rm -rf "$TOOLS" "$LICENSES"
mkdir -p "$TOOLS" "$LICENSES"
cp -pR "$ROOT/vendor/toolchain/Tools/yt-dlp" "$TOOLS/yt-dlp"
cp -p "$ROOT/vendor/toolchain/Tools/ffmpeg" "$TOOLS/ffmpeg"
cp -p "$ROOT/vendor/toolchain/Tools/ffprobe" "$TOOLS/ffprobe"
cp -p "$ROOT/vendor/toolchain/Tools/qjs" "$TOOLS/qjs"
cp -pR "$ROOT/vendor/toolchain/Licenses/." "$LICENSES"
for tool in ffmpeg ffprobe qjs; do
  chmod 755 "$TOOLS/$tool"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$TOOLS/$tool"
done
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
printf '{\n  "yt-dlp": "%s",\n  "ffmpeg": "%s",\n  "ffprobe": "%s",\n  "qjs": "%s"\n}\n' \
  "$(hash "$TOOLS/yt-dlp/yt-dlp_macos")" "$(hash "$TOOLS/ffmpeg")" \
  "$(hash "$TOOLS/ffprobe")" "$(hash "$TOOLS/qjs")" \
  > "$DEST/Toolchain.runtime.json"
