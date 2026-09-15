#!/usr/bin/env bash
# Reproduce the private local Phone Scorer package. No inference Python is shipped.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/echolab-phone-convert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REVISION=2211f19be4abc6cdfb7908eb9bbb34f9dcccb550
git clone https://github.com/aviadarn/Accentedness-Scoring-Challenge.git "$WORK/source"
git -C "$WORK/source" checkout --detach "$REVISION"
uv venv --python 3.11 "$WORK/env"
uv pip install --python "$WORK/env/bin/python" -r "$ROOT/scripts/assessment/conversion-requirements.txt"
HF_HUB_OFFLINE=1 "$WORK/env/bin/python" "$ROOT/scripts/assessment/export_phone.py" \
  --source "$WORK/source" --output "$WORK/package"
# Validate expected model bytes before publishing to the build input directory.
(cd "$WORK/package" && shasum -a 256 -c "$ROOT/scripts/assessment/phone-checksums.sha256")
mkdir -p "$ROOT/vendor/phone-scorer"
cp "$WORK/package/"* "$ROOT/vendor/phone-scorer/"

cp "$ROOT/scripts/assessment/PHONE-NOTICE.txt" "$ROOT/vendor/phone-scorer/NOTICE.txt"
