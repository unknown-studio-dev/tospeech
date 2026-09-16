#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/alignment"
if [[ ! -d "$SOURCE/EnglishAlignment.mlmodelc" ]]; then
  echo 'Missing word-alignment package. Run: bash scripts/alignment/prepare.sh' >&2
  exit 1
fi
(cd "$SOURCE" && shasum -a 256 -c "$ROOT/scripts/alignment/alignment-manifest.sha256")
# Manifest identity is pinned above. Verify every listed file before staging.
/usr/bin/python3 - "$SOURCE" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
for name, expected in json.loads((root/'checksums.json').read_text()).items():
    path = Path(name)
    assert not path.is_absolute() and '..' not in path.parts
    digest = hashlib.sha256()
    with (root/path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''): digest.update(chunk)
    if digest.hexdigest() != expected: raise SystemExit('Alignment package checksum mismatch: '+name)
PY
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Alignment"
mkdir -p "$DEST"
# weight.bin resolves from the container CoreMLWordAligner loads from
# (AlignmentPackage.directory), which the app downloads at onboarding
# (AlignmentPackage.weightsURL). Release leaves the 188 MB file out of the
# bundle; Debug keeps it so development and tests stay offline.
if [ "${CONFIGURATION:-}" = Release ]; then
  rsync -a --delete --delete-excluded --exclude 'weights/weight.bin' "$SOURCE/EnglishAlignment.mlmodelc/" "$DEST/EnglishAlignment.mlmodelc/"
else
  rsync -a --delete "$SOURCE/EnglishAlignment.mlmodelc/" "$DEST/EnglishAlignment.mlmodelc/"
fi
cp "$SOURCE/vocab.json" "$SOURCE/provenance.json" "$SOURCE/checksums.json" "$DEST/"
cp "$ROOT/scripts/alignment/LICENSE" "$DEST/LICENSE"
