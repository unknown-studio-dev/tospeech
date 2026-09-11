# EchoLab native app structure

SwiftUI migration authorized 2026-09-10. Minimum macOS 26, arm64 only.
Normal launches use production B1 Library plus the B2 playback/capture service
foundation. Progress, Settings and `--preview-fixtures` retain preview adapters.

```text
native/
  project.yml                   # Reproducible XcodeGen project definition
  EchoLab.xcodeproj/             # Open and run in Xcode; generated and shipped
  EchoLab/
    App/                        # Entry point, composition, navigation
    Domain/
      Models/                   # Typed value models and state enums
      Rules/                    # Pure timing/validation/comparison rules
    DesignSystem/               # Semantic tokens, typography, controls, sheets, brand
      Preview/                  # Interactive component gallery, no lesson persistence
    Features/
      Library/                  # Grid, import and deletion
      Shadowing/                # Practice screen and feature-local components
        Components/
        Timing/
        Pronunciation/
        Review/
      Progress/                 # Video-scoped history and comparable trends
      Settings/                 # General, recording, model packages
    Services/
      Preview/                  # Observable store, simulated jobs/capture, preview persistence
      Production/               # Local backend services; persistence/media/jobs by capability
    Mocks/                      # All sample content and scores, no fixtures in views
    Resources/                  # Bundled preview thumbnails
      Brand.xcassets/           # Transparent toucan + macOS AppIcon size set
      en.lproj/                 # English UI strings
      vi.lproj/                 # Vietnamese UI strings
  EchoLabTests/                 # Behavioral rules, persistence and lifecycle tests
```

One app module initially, with explicit folder ownership. Do not create a target
per screen or move everything into a generic Helpers folder. Extract modules
when a real independent dependency/lifecycle warrants it. Features can consume
Domain, DesignSystem and Services. Domain imports Foundation only; it never
imports SwiftUI, a feature, or a preview service. Shared controls do not know
about lessons or scoring. App is the composition root.

Localization is app-owned presentation infrastructure. `AppLanguage` is the
persisted domain preference; the composition root injects its `Locale`.
`EchoLocalization` in DesignSystem resolves runtime `String` labels used by
shared controls. Feature content such as transcripts, IPA, lesson names and
user input is data and must not be routed through the UI string catalogs.

Feature-specific types and logic stay within their feature unless shared by
another feature. Cross-feature navigation goes through the store, never through
one feature view reaching into another view's state. A feature may own several
small view files; avoid screen-sized declarations mixed with data fixtures.

## UI component ownership (required)

Feature screens compose DesignSystem controls; they do not define ButtonStyle,
ToggleStyle, TextFieldStyle, raw text inputs/selects/sliders, or re-skin controls.
Use EchoButton/EchoIconButton, EchoTextField/EchoNumberField, EchoSelect,
EchoSegmented/EchoCheckbox/EchoToggleStyle, EchoRowButton and the shared transport
and media-thumbnail controls. New variants belong in DesignSystem with catalog
coverage, not in individual screens. Domain callbacks remain in Features.

Native macOS menu and confirmation actions are deliberate exceptions, marked
`// native-control: menu` or `// native-control: confirmation` at the call site.
App-level `.commands` also stays native. Do not use these annotations on content
controls to bypass reuse. Layout containers, lesson content, charts and the timing
waveform remain feature-specific; a shared button does not require a generic screen.

Xcode runs `scripts/check-ui-components.sh` before every build to catch new direct
control/style implementations in Features. This is a source guard, not visual QA.

`EchoStore` and `PracticeController` remain preview services for Shadowing,
Progress, Settings and component/render fixtures. Their Codable snapshot is not
the production schema. Countdown, recording, VAD, translation and assessment
remain simulated. `--preview-fixtures` does not initialize `BackendPaths` or the
production database.

Normal Library composition uses `ProductionLibraryModel`,
`ProductionImportService`, `ProductionDatabase` and managed `BackendPaths`. Import
executables live in `EchoLab.app/Contents/Resources/Tools`; yt-dlp uses the latest
official macOS onedir archive rather than the same release's sandbox-incompatible
onefile binary. The build verifies its pinned archive/root executable, preserves
the upstream embedded Mach-O signatures, then writes runtime checksums before final
app signing. Helper temporary files,
import workspaces and commit/deletion manifests live under
`Cache/ImportJobs`; durable M4A/JPG assets live under `Media`. Features consume
typed summaries/jobs and never SQL, stored relative paths or SQLite handles.

B1 is audio-only Library persistence. A ready production lesson deliberately has
a disabled practice action until later slices provide real preparation/playback.
No generic repository, local server, web business bridge or local video file is
introduced.

B2 lives in `Services/Production/Practice`: frame-range playback owns the native
audio clock; microphone capture writes managed CAF staging; SQLite stores immutable
round targets and independent takes; launch recovery replays take manifests. B3 adds
prepared SegmentRevision projection for native Shadowing (tokens, offline IPA,
translation annotation, timing revisions and managed-take replay). Preview fixtures
remain separate from that route. Assessment/scoring is still a later slice.

Build: `xcodebuild -project native/EchoLab.xcodeproj -scheme EchoLab -configuration Debug -derivedDataPath native/.build build`

Test: same command ending in `test` with destination `platform=macOS,arch=arm64`.
If source/spec changes require regeneration: `cd native && xcodegen generate`.
XcodeGen is for maintainers; opening the checked-in generated project needs no
pnpm, Vite or XcodeGen on a colleague's machine.

## Native foundation preview — 2026-09-10

Open **Design → UI Components…** (`⌘⌥D`) to inspect the shared components.
The gallery is a separate native window. Its sample values live in
`Mocks/DesignSystemFixtures.swift`; local control state never saves lesson data.
`--preview-fixtures --components` opens this gallery with in-memory app data.
Settings is a route in the main window (user override, 2026-09-10), opened from
the sidebar or ⌘,. All entry points use the store navigation guard; preferences
still persist immediately. The earlier separate Settings window is superseded.

Fonts use SwiftUI system fonts (SF Pro / monospaced system font), not bundled web
fonts. Semantic colors live only in `EchoTheme`; sizing in `EchoMetrics`; motion
in `EchoMotion`. Older color aliases remain temporarily for feature compatibility.
`EchoControlState` centralizes loading/disabled/error/success. Feature controllers
still own real submission, cancellation and draft confirmation decisions.

Debug-only `--preview-fixtures --render-previews` exports app-owned SwiftUI views
to the sandbox temporary `EchoLabPreviews` directory and exits. These are render
checks, not evidence of live audio, accessibility automation or complete screen parity.
See `../docs/UI_NATIVE_FOUNDATION_HANDOFF.md` for scope and verification.
