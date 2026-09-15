#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/deepfilternet/deep-filter"
[ -x "$SOURCE" ] || { echo 'Missing DeepFilterNet; run bash scripts/audio/fetch-deepfilternet.sh' >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
[ "$ACTUAL" = 4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081 ] || {
  echo 'DeepFilterNet release checksum mismatch' >&2; exit 1;
}
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DeepFilterNet"
mkdir -p "$DEST"
cp "$SOURCE" "$DEST/deep-filter"
chmod 755 "$DEST/deep-filter"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$ROOT/scripts/audio/SandboxedHelper.entitlements" "$DEST/deep-filter"
