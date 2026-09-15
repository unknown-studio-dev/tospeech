#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/uk-reference"
(cd "$SOURCE" && shasum -a 256 -c "$ROOT/scripts/assessment/uk-manifest.sha256")
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
    if digest.hexdigest() != expected: raise SystemExit('UK package checksum mismatch: '+name)
PY
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/UKReference"
mkdir -p "$DEST"
# encoder.onnx reads its weights from the upstream checkpoint, which the app downloads
# from Hugging Face at onboarding (UKReferencePackage.weightsURL). Release leaves the
# 1,26 GB file out of the bundle; Debug keeps it so development and tests stay offline.
if [ "${CONFIGURATION:-}" = Release ]; then
  rsync -a --delete --delete-excluded --exclude 'pytorch_model.bin' "$SOURCE/" "$DEST/"
else
  rsync -a --delete "$SOURCE/" "$DEST/"
fi
