#!/bin/bash
# macOS built-ins only: this guard also runs inside Xcode without Homebrew PATH.
set -euo pipefail
native_root="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0
while IFS= read -r -d '' source_file; do
  if ! /usr/bin/awk '
    /^[[:space:]]*\/\// { next }
    /(^|[^[:alnum:]_])(TextField|TextEditor|Picker|Slider)[[:space:]]*\(/ ||
    /(^|[^[:alnum:]_])ProgressView[[:space:]]*\(/ ||
    /:[[:space:]]*(ButtonStyle|TextFieldStyle|ToggleStyle)([[:space:]]|\{)/ ||
    /\.buttonStyle[[:space:]]*\(/ ||
    /\.textFieldStyle[[:space:]]*\(/ ||
    /\.toggleStyle[[:space:]]*\(\./ {
      print FILENAME ":" FNR ": error: Use the shared DesignSystem control, not feature-local chrome."
      failed = 1
    }
    /(^|[^[:alnum:]_])Button[[:space:]]*[(\{]/ {
      if ($0 !~ /\/\/ native-control: (menu|confirmation)/) {
        print FILENAME ":" FNR ": error: Use EchoButton, EchoIconButton or a shared semantic control."
        failed = 1
      }
    }
    END { exit failed ? 1 : 0 }
  ' "$source_file"; then
    failed=1
  fi
done < <(/usr/bin/find "$native_root/ToSpeech/Features" "$native_root/ToSpeech/App/AppRootView.swift" -name '*.swift' -type f -print0)

shadowing="$native_root/ToSpeech/Features/Shadowing"
require_source() {
  local file="$1"
  local pattern="$2"
  if ! /usr/bin/grep -Fq "$pattern" "$file"; then
    echo "$file: error: Production Shadowing must reuse '$pattern'."
    failed=1
  fi
}
for component in \
  'ShadowingPracticeScaffold(' 'ProductionTakeReviewView(' \
  'VideoPreviewView(' 'TranscriptNavigatorView(' \
  'SentenceView(' 'PracticeTransportView('
do
  require_source "$shadowing/ProductionShadowingView.swift" "$component"
done
# Repeat presentation lives on the shared transport's actual trigger buttons.
require_source "$shadowing/Components/PracticeTransportView.swift" 'RepeatOptionsView('
require_source "$shadowing/ProductionShadowingView.swift" 'optionsPresented: $showingRepeatOptions'
require_source "$shadowing/ProductionPreparationSheets.swift" 'WordPronunciationView('
require_source "$shadowing/ProductionPreparationSheets.swift" 'TimingEditorView('

if /usr/bin/grep -Eq 'previewBody|productionBody|productionNormal|productionCapture' \
  "$shadowing/Components/PracticeTransportView.swift"; then
  echo "$shadowing/Components/PracticeTransportView.swift: error: Keep one shared transport renderer."
  failed=1
fi
if /usr/bin/grep -Eq 'EchoDialog\(|EchoNumberField\(|WordFlowLayout\(' \
  "$shadowing/ProductionPreparationSheets.swift"; then
  echo "$shadowing/ProductionPreparationSheets.swift: error: Production sheets must remain data/action adapters."
  failed=1
fi
require_source "$shadowing/Components/PracticeTransportView.swift" 'EchoTransportBar('
require_source "$shadowing/Components/PracticeTransportView.swift" 'EchoPlaybackControls('
if /usr/bin/grep -Eq '"backward.end"|"forward.end"' "$shadowing/Components/PracticeTransportView.swift"; then
  echo "$shadowing/Components/PracticeTransportView.swift: error: Previous/play/next belong in shared EchoPlaybackControls."
  failed=1
fi
exit "$failed"
