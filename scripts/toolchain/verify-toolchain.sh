#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="$ROOT/vendor/toolchain/Tools"
LICENSES="$ROOT/vendor/toolchain/Licenses"

hash() { shasum -a 256 "$1" | awk '{print $1}'; }
require() { [[ -x "$1" ]] || { echo "missing executable: $1" >&2; exit 1; }; }
require_hash() { [[ "$(hash "$1")" == "$2" ]] || { echo "checksum mismatch: $1" >&2; exit 1; }; }
require_arm64() { [[ "$(lipo -archs "$1")" == *"arm64"* ]] || { echo "not arm64: $1" >&2; exit 1; }; }

require "$TOOLS/yt-dlp/yt-dlp_macos"
require "$TOOLS/ffmpeg"
require "$TOOLS/ffprobe"
require "$TOOLS/qjs"
require_hash "$TOOLS/yt-dlp/yt-dlp_macos" "4f54eb67e4e96c7c3ffa49dd5deb81bc348bbb495080889b47d157d5c6d74443"
require_hash "$TOOLS/ffmpeg" "8920fb6559fb2e0e137ee4d1c29bbbbedd283a39b65c6a883f655e07974d4057"
require_hash "$TOOLS/ffprobe" "514e4244eed651fbdb31a242d75045f72c4e3e0d6ed8a9182c3d33139b880f56"
require_hash "$TOOLS/qjs" "88b92796e3f471f613fdee4b5fefa87d2f86bf7d923179b857f3cff3965c9eb0"
for tool in yt-dlp/yt-dlp_macos ffmpeg ffprobe qjs; do require_arm64 "$TOOLS/$tool"; done
[[ -s "$LICENSES/yt-dlp-THIRD_PARTY_LICENSES.txt" ]] || { echo "missing yt-dlp notices" >&2; exit 1; }
[[ -s "$LICENSES/FFmpeg-LGPL-source-offer.txt" ]] || { echo "missing FFmpeg source offer" >&2; exit 1; }
[[ -s "$LICENSES/QuickJS-MIT.txt" ]] || { echo "missing QuickJS license" >&2; exit 1; }
"$TOOLS/yt-dlp/yt-dlp_macos" --version
"$TOOLS/ffmpeg" -version >/dev/null
"$TOOLS/ffprobe" -version >/dev/null
"$TOOLS/qjs" --version

echo "Verified bundled arm64 import toolchain"
