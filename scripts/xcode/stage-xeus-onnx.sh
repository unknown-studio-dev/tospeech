#!/usr/bin/env bash
set -euo pipefail
# Stages the SMALL PhoneticXeus native-ONNX assets into the app bundle:
#   xeus.onnx (graph, ~0.6 MB) + ipa_vocab.json + uk-contrast-head.json + thresholds.json.
# The heavy xeus.onnx.data (~2.3 GB external-data weights) is NOT bundled; the app downloads it at
# onboarding (PhoneticXeusPackage.weightsURL) and verifies its sha256. Best-effort: if a source is
# missing (e.g. the exported graph has not been produced locally) this stages what it can and exits
# 0 so the build still succeeds — the engine card simply stays hidden until the assets are present.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH="$ROOT/.build/xeus-onnx/xeus.onnx"
VOCAB="$ROOT/scripts/assessment/phoneticxeus/ipa_vocab.json"
HEAD="$ROOT/scripts/assessment/phoneticxeus/uk-contrast-head.json"
THRESHOLDS="$ROOT/scripts/assessment/phoneticxeus/thresholds.json"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PhoneticXeus"
mkdir -p "$DEST"
copy() { [ -f "$1" ] && cp -f "$1" "$DEST/$(basename "$1")" || echo "stage-xeus-onnx: missing $(basename "$1") ($1)" >&2; }
copy "$GRAPH"
copy "$VOCAB"
copy "$HEAD"
copy "$THRESHOLDS"
exit 0
