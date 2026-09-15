#!/usr/bin/env bash
# Copies the GPL rubberband-render helper (built by the RubberBandRender tool
# target) into the app bundle as a separate executable. The app talks to it
# through files only; Rubber Band is never linked into ToSpeech itself.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${BUILT_PRODUCTS_DIR:?Xcode must supply BUILT_PRODUCTS_DIR}"
: "${TARGET_BUILD_DIR:?Xcode must supply TARGET_BUILD_DIR}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode must supply resource path}"
SOURCE="$BUILT_PRODUCTS_DIR/rubberband-render"
[ -x "$SOURCE" ] || { echo 'Missing rubberband-render; the RubberBandRender target must build before ToSpeech.' >&2; exit 1; }
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/RubberBand"
mkdir -p "$DEST"
cp "$SOURCE" "$DEST/rubberband-render"
chmod 755 "$DEST/rubberband-render"
cp "$ROOT/ThirdParty/RubberBand/COPYING" "$DEST/COPYING"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$ROOT/scripts/audio/SandboxedHelper.entitlements" "$DEST/rubberband-render"
