#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/phone-scorer"
(cd "$SOURCE" && shasum -a 256 -c "$ROOT/scripts/assessment/phone-checksums.sha256")
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PhoneScorer"
mkdir -p "$DEST"
rsync -a --delete "$SOURCE/" "$DEST/"
