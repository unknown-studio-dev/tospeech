#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/alignment"
if [[ ! -d "$SOURCE/EnglishAlignment.mlmodelc" ]]; then
  echo 'Missing word-alignment package. Run: bash scripts/alignment/prepare.sh' >&2
  exit 1
fi
(cd "$SOURCE" && shasum -a 256 -c "$ROOT/scripts/alignment/checksums.sha256")
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Alignment"
mkdir -p "$DEST"
rsync -a --delete "$SOURCE/EnglishAlignment.mlmodelc/" "$DEST/EnglishAlignment.mlmodelc/"
cp "$SOURCE/vocab.json" "$SOURCE/provenance.json" "$DEST/"
cp "$ROOT/scripts/alignment/LICENSE" "$DEST/LICENSE"
