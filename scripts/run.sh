#!/usr/bin/env bash
#
# ToSpeech — native macOS app runner
# Usage:
#   scripts/run.sh                # build (Debug) + launch the app
#   scripts/run.sh build          # build only, no launch
#   scripts/run.sh run            # launch the last build without rebuilding
#   scripts/run.sh test           # build + run the Swift Testing suite
#   scripts/run.sh gen            # regenerate ToSpeech.xcodeproj from project.yml (xcodegen)
#   scripts/run.sh components      # build + launch the UI Components gallery (in-memory fixtures)
#   scripts/run.sh render          # build + export app-owned SwiftUI views as PNGs, then exit
#   scripts/run.sh clean          # remove the .build derived-data directory
#
# Requires: Xcode 26+, Apple Silicon, macOS 26+. xcodegen only for `gen`.

set -euo pipefail

# Always operate relative to this script's own directory (the repo root, one level above scripts/).
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="ToSpeech.xcodeproj"
SCHEME="ToSpeech"
CONFIG="Debug"
DERIVED="$PWD/.build"
APP="$DERIVED/Build/Products/$CONFIG/ToSpeech.app"
BIN="$APP/Contents/MacOS/ToSpeech"
DEST="platform=macOS,arch=arm64"

xcb() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" -destination "$DEST" \
    -derivedDataPath "$DERIVED" "$@"
}

build() { echo "▶ Building $SCHEME ($CONFIG)…"; xcb build; }

launch() {
  [ -d "$APP" ] || { echo "✗ No build found at $APP — run 'scripts/run.sh build' first."; exit 1; }
  echo "▶ Launching $APP"
  open "$APP"
}

cmd="${1:-}"
case "$cmd" in
  ""|dev)      build; launch ;;
  build)       build ;;
  run)         launch ;;
  test)        echo "▶ Testing…"; xcb test ;;
  gen)         command -v xcodegen >/dev/null || { echo "✗ xcodegen not installed (brew install xcodegen)"; exit 1; }
               echo "▶ Regenerating project from project.yml…"; xcodegen generate ;;
  components)  build
               [ -x "$BIN" ] || { echo "✗ Binary missing at $BIN"; exit 1; }
               echo "▶ Opening UI Components gallery…"
               "$BIN" --preview-fixtures --components ;;
  render)      build
               [ -x "$BIN" ] || { echo "✗ Binary missing at $BIN"; exit 1; }
               echo "▶ Exporting SwiftUI view PNGs…"
               "$BIN" --preview-fixtures --render-previews ;;
  clean)       echo "▶ Removing $DERIVED"; rm -rf "$DERIVED" ;;
  -h|--help|help)
               sed -n '2,20p' "$0" ;;
  *)           echo "✗ Unknown command: $cmd"; sed -n '2,20p' "$0"; exit 1 ;;
esac
