#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR="$ROOT/vendor/toolchain"
DOWNLOADS="$VENDOR/downloads"
BUILD="$VENDOR/build"
TOOLS="$VENDOR/Tools"
NOTICES="$VENDOR/Licenses"

YTDLP_VERSION="2026.08.19"
YTDLP_SOURCE_SHA="072aad4f2a7604e92155f61a275a4752dc64046c8f6d90df3710525d94cd37c1"
YTDLP_ONEDIR_ARCHIVE_SHA="07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"
YTDLP_EXEC_SHA="4f54eb67e4e96c7c3ffa49dd5deb81bc348bbb495080889b47d157d5c6d74443"
FFMPEG_SOURCE_SHA="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
QUICKJS_SOURCE_SHA="b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a"
YTDLP_NOTICES_SHA="472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7"
FFMPEG_SHA="8920fb6559fb2e0e137ee4d1c29bbbbedd283a39b65c6a883f655e07974d4057"
FFPROBE_SHA="514e4244eed651fbdb31a242d75045f72c4e3e0d6ed8a9182c3d33139b880f56"
QJS_SHA="88b92796e3f471f613fdee4b5fefa87d2f86bf7d923179b857f3cff3965c9eb0"
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
require_hash() {
  local file="$1" expected="$2"
  [[ "$(hash "$file")" == "$expected" ]] || {
    echo "checksum mismatch: $file" >&2
    exit 1
  }
}
download() {
  local url="$1" output="$2" expected="$3"
  if [[ ! -f "$output" ]]; then curl --fail --location --proto '=https' --tlsv1.2 "$url" -o "$output"; fi
  require_hash "$output" "$expected"
}
require_arm64() {
  [[ "$(lipo -archs "$1")" == *"arm64"* ]] || { echo "not arm64: $1" >&2; exit 1; }
}

rm -rf "$BUILD" "$TOOLS" "$NOTICES"
mkdir -p "$DOWNLOADS" "$BUILD" "$TOOLS" "$NOTICES"

download "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp.tar.gz" "$DOWNLOADS/yt-dlp.tar.gz" "$YTDLP_SOURCE_SHA"
download "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos.zip" "$DOWNLOADS/yt-dlp_macos.zip" "$YTDLP_ONEDIR_ARCHIVE_SHA"
download "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz" "$DOWNLOADS/ffmpeg-9.0.1.tar.xz" "$FFMPEG_SOURCE_SHA"
download "https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz" "$DOWNLOADS/quickjs-2026-06-04.tar.xz" "$QUICKJS_SOURCE_SHA"
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/THIRD_PARTY_LICENSES.txt" "$DOWNLOADS/yt-dlp-THIRD_PARTY_LICENSES.txt" "$YTDLP_NOTICES_SHA"

tar -xzf "$DOWNLOADS/yt-dlp.tar.gz" -C "$BUILD"
mkdir -p "$TOOLS/yt-dlp"
unzip -q "$DOWNLOADS/yt-dlp_macos.zip" -d "$TOOLS/yt-dlp"
chmod 755 "$TOOLS/yt-dlp/yt-dlp_macos"
tar -xJf "$DOWNLOADS/ffmpeg-9.0.1.tar.xz" -C "$BUILD"
tar -xJf "$DOWNLOADS/quickjs-2026-06-04.tar.xz" -C "$BUILD"
perl -0pi -e 's/CFLAGS\+=-g -Wall/CFLAGS+=-g0 -Wall/; s/LDFLAGS\+=-g\n/LDFLAGS+=-g0\n/' "$BUILD/quickjs-2026-06-04/Makefile"

sed -i '' '356i\
            if (!strcmp(longopt, "version")) { puts(CONFIG_VERSION); return 0; }
' "$BUILD/quickjs-2026-06-04/qjs.c"
ffmpeg_dir="$BUILD/ffmpeg-9.0.1"
(
  cd "$ffmpeg_dir"
  ./configure --arch=arm64 --target-os=darwin --disable-shared --enable-static --disable-debug --disable-doc --disable-ffplay --enable-ffmpeg --enable-ffprobe
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe
  install -m 755 ffmpeg ffprobe "$TOOLS"
)
(
  cd "$BUILD/quickjs-2026-06-04"
  make -j"$(sysctl -n hw.ncpu)" qjs
  xcrun swift "$ROOT/scripts/toolchain/fix-macho-uuid.swift" qjs 4F3B9062-5B7B-4D9A-9499-BFD3EA1CA2B5
  codesign --force --sign - qjs
  install -m 755 qjs "$TOOLS/qjs"
)

cp "$DOWNLOADS/yt-dlp-THIRD_PARTY_LICENSES.txt" "$NOTICES/yt-dlp-THIRD_PARTY_LICENSES.txt"
cat >"$NOTICES/FFmpeg-LGPL-source-offer.txt" <<'NOTICE'
ToSpeech bundles FFmpeg 9.0.1 built from source under LGPL-2.1-or-later.
The exact source archive, SHA-256, and build configuration are in scripts/toolchain/Toolchain.lock.json.
For the corresponding source and build instructions, see native/scripts/fetch-toolchain.sh
or obtain the unmodified source from https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.
NOTICE
cp "$BUILD/quickjs-2026-06-04/LICENSE" "$NOTICES/QuickJS-MIT.txt"

for tool in yt-dlp/yt-dlp_macos ffmpeg ffprobe qjs; do
  [[ -x "$TOOLS/$tool" ]] || { echo "missing executable: $tool" >&2; exit 1; }
  require_arm64 "$TOOLS/$tool"
done
require_hash "$TOOLS/yt-dlp/yt-dlp_macos" "$YTDLP_EXEC_SHA"
require_hash "$TOOLS/ffmpeg" "$FFMPEG_SHA"
require_hash "$TOOLS/ffprobe" "$FFPROBE_SHA"
require_hash "$TOOLS/qjs" "$QJS_SHA"

printf '{\n  "yt-dlp": "%s",\n  "ffmpeg": "%s",\n  "ffprobe": "%s",\n  "qjs": "%s"\n}\n' \
  "$(hash "$TOOLS/yt-dlp/yt-dlp_macos")" "$(hash "$TOOLS/ffmpeg")" \
  "$(hash "$TOOLS/ffprobe")" "$(hash "$TOOLS/qjs")" \
  > "$VENDOR/executable-shas.json"

echo "Verified toolchain staged at $VENDOR"
