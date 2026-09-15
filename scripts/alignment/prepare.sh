#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Maintainer tool only. The shipped app uses Core ML, not this Python environment.
uv venv --python 3.12 "$ROOT/vendor/alignment-converter"
uv pip install --python "$ROOT/vendor/alignment-converter/bin/python" \
  torch==2.5.0 transformers==4.46.3 coremltools==8.3.0 numpy==1.26.4
"$ROOT/vendor/alignment-converter/bin/python" "$ROOT/scripts/alignment/convert_wav2vec2.py"
xcrun coremlcompiler compile "$ROOT/vendor/alignment/EnglishAlignment.mlpackage" "$ROOT/vendor/alignment"
