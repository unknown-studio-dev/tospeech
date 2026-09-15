#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$ROOT/vendor/deepfilternet"
mkdir -p "$DEST"
TEMP_BINARY="$(mktemp "$DEST/download.XXXXXX")"
trap 'rm -f "$TEMP_BINARY"' EXIT
curl --fail --location --retry 2 \
  https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-aarch64-apple-darwin \
  -o "$TEMP_BINARY"
ACTUAL="$(shasum -a 256 "$TEMP_BINARY" | awk '{print $1}')"
[ "$ACTUAL" = 4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081 ] || {
  echo 'DeepFilterNet release checksum mismatch' >&2; exit 1;
}
chmod 755 "$TEMP_BINARY"
mv "$TEMP_BINARY" "$DEST/deep-filter"
