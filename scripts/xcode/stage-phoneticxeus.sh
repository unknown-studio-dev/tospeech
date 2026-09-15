#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/vendor/phoneticxeus"
# Reproduce with scripts/assessment/phoneticxeus/package.py before building.
[ -x "$SOURCE/xeus-helper" ] || { echo 'Missing PhoneticXeus runtime; run its package.py first.' >&2; exit 1; }
/usr/bin/python3 - "$SOURCE" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
if hashlib.sha256((root/'checksums.json').read_bytes()).hexdigest() != '4e479a3d14fbdad167e0077004200228103faf5b2cbdb5e6e265829690f0343b': raise SystemExit('Unpinned PhoneticXeus runtime manifest')
for name,expected in json.loads((root/'checksums.json').read_text()).items():
 path=Path(name)
 if path.is_absolute() or '..' in path.parts: raise SystemExit('Invalid runtime manifest path')
 h=hashlib.sha256()
 with (root/path).open('rb') as f:
  for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
 if h.hexdigest()!=expected:raise SystemExit('PhoneticXeus runtime checksum mismatch: '+name)
PY
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PhoneticXeus"
mkdir -p "$DEST"
rsync -a --delete "$SOURCE/" "$DEST/"
