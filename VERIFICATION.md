# Native implementation handoff — 2026-09-10

This began as the SwiftUI UI migration and now includes production Library B1
plus the B2 playback/capture service foundation. Lesson preparation and assessment
remain later slices.
The legacy React prototype is preserved. There is no automatic browser-data import.

## Implemented structure and preview behavior

| Area | Native ownership and behavior |
| --- | --- |
| App | Single window, navigation, settings presentation, close/quit capture guard |
| Library | Production YouTube/local-audio import, durable job recovery, search, ready audio cards and confirmed B1 deletion; fixtures remain separately injectable |
| Shadowing | Scroll/search transcript, word + IPA + VI, pronunciation sheet, pinned transport, listen-first capture state machine |
| Timing | Draft transcript/translation, source/word bounds, move vs trim, baseline reset, optimistic revision checks |
| Review | Whole sentence/phrase, take/result selection, fixed engine provenance, retained ungraded takes, retry/re-score |
| Progress | Video-scoped history, filters and compatible sentence/profile score trends |
| Settings | General/recording/model sections, one active engine, package simulation and removal protection |
| Shared | Typed domain values/rules, controls/tokens, local preview store, fixtures outside views |

## Initial UI verification

- Xcode 26.2, Swift 6 strict concurrency, arm64, macOS 26.5 host.
- Debug build and 18 Swift Testing tests passed. Tests cover timing validation,
  token identity/reordering, numeric move, listen-before-record, no-speech,
  interrupted capture, save failure/retry, immutable take context, engine identity,
  URL validation and local snapshot persistence/recovery.
- App-owned NSHostingView renders inspected for Library, Shadowing, Progress at
  1440×960 and 1000×740, plus Settings, pronunciation, timing and review surfaces.
  This is visual rendering plus state tests, not a complete click-through/XCUITest
  or accessibility audit. Scrollable content extends beyond the smaller viewport.
- Fixed missing bundled image resources, constrained picker labels stretching
  sentence cards, whole-video timing scale, and historical score/provenance mixing.

Reproduce build/tests using README commands. Debug-only view export:

```sh
native/.build/Build/Products/Debug/EchoLab.app/Contents/MacOS/EchoLab --preview-fixtures --render-previews
```

It writes PNGs to the app's temporary EchoLabPreviews directory and prints the
path. It renders only app-owned views, not other desktop windows. Launching with
`--preview-fixtures` avoids both the normal preview metadata store and production
Library initialization.

## Remaining boundaries

The original migration boundaries above are superseded in part by B3 below:
caption preparation, offline IPA and a muted WebKit YouTube follower are now in the
production code. A physical Apple Speech/Translation permission run, a live
YouTube/WebKit acceptance pass, model installation, scoring and benchmarks remain
unverified. Preview metadata remains separate local JSON.

Native UI parity still needs a dedicated interactive audit against all Pencil
states. Advanced repeat modes (custom/until-stopped and relative waits), true
sentence-only preference overrides, OS device/calibration and detailed
asset/storage-management surfaces are not claimed complete by this migration.
Packaging for colleagues still needs release signing/notarization and distribution
compliance review; the current Xcode build uses local ad-hoc signing. B1 bundles
the verified dependency license/source-offer files listed below.

## Backend B0 follow-up — 2026-09-10

The first production backend kernel was introduced alongside the preview
composition. B1 below now substitutes it only for the normal Library route:

- `BackendPaths` creates the declared Application Support layout without creating
  production data during UI preview startup.
- `ProductionDatabase` owns one SQLite connection in a Swift actor, enables
  foreign keys, WAL and full synchronous durability, and migrates schema v1 in
  an immediate transaction.
- Schema v1 covers the production identities and relationships for lessons,
  media assets, segment revisions, practice rounds/takes, engine releases,
  assessments and jobs. Feature views do not access it directly.
- The implemented repository slice inserts/reads Lesson identity and marks a
  lesson deleting with an optimistic generation fence. Duplicate provider IDs,
  stale deletion callbacks and newer unsupported schemas are rejected.

Xcode 26.2 Debug build and the complete suite pass: **65 tests, 0 failures**.
Five production persistence tests cover directory creation, migration reopen,
foreign-key enablement/integrity, newer-schema preservation, duplicate import
identity and deletion fencing. At B0 this did not claim import, playback, capture,
speech, translation or scoring. B1 below adds import only; later slices remain in
`../docs/BACKEND_SYSTEM_DESIGN.md`.

## Backend B1 Library slice — 2026-09-10

- The normal Library route creates the production Application Support layout and
  SQLite database; initialization/relaunch recovery errors remain visible with a
  retry action instead of falling back to sample data. `--preview-fixtures` keeps
  the old in-memory Library and does not initialize production storage.
- Public YouTube and selected local audio imports normalize exactly one source
  audio asset to M4A, retain metadata/thumbnail, and never publish a video file.
- The latest stable yt-dlp release is 2026.08.19. EchoLab uses its official
  `yt-dlp_macos.zip` onedir asset with pinned archive/executable hashes, plus
  FFmpeg/FFprobe 9.0.1 and QuickJS 2026-06-04. The onefile sibling is excluded.
- SQLite persists immutable attempt run tokens and checkpoints. Retry validates
  retained audio before reuse; relaunch replays a commit manifest after file rename;
  stale attempts and deleted generations cannot publish.
- Confirmed delete persists intent before lifecycle `deleting`, removes only B1
  managed media and metadata, and resumes after partial file or database failure.

Verification on the macOS 26.5 arm64 host:

- `./run.sh build` succeeded, including the shared-component guard and staged
  toolchain verification/signing phase.
- `./run.sh test` succeeded: **74 tests in 7 suites, 0 failures**. The 13-test
  production persistence suite includes official macOS onedir yt-dlp startup
  inside App Sandbox, real local WAV→M4A import, no-video output, deletion
  failure/relaunch completion, failed→retry attempt fencing, subprocess
  streaming/cancellation, and rename-before-database-commit recovery. A separate
  URL→local-file regression ensures clearing the URL retains the chosen audio file.
- `scripts/verify-toolchain.sh` validated every pinned executable. A live public
  YouTube import (`jNQXAC9IVRw`) ran through `ProductionImportService` with the
  official onedir build inside App Sandbox and reached `ready`; final managed
  output contained one M4A source audio file and one JPEG thumbnail. The throwaway
  database/files were removed.
- A clean ad-hoc Release build passed strict deep code-sign verification and
  measured **178 MB total**, including **167 MB** of bundled import tools/runtime.
  The 536 MB local rebuild workspace is ignored and is not part of the app. App
  resources include upstream yt-dlp third-party notices, QuickJS MIT text and the
  FFmpeg LGPL source offer.
- `./run.sh render` completed with `--preview-fixtures`; normal Library and
  preview component-gallery executables also remained running during process smoke.
  Interactive desktop inspection was not available because the Orca app runtime
  was not started, so this pass does not claim visual click-through verification.

## Backend B2 playback/capture foundation — 2026-09-11

- `ProductionAudioPlayer` schedules immutable source-frame ranges, preserves pitch
  across 0.25–4× speed, and exposes render-derived source position for pause/seek.
- `ProductionAudioRecorder` requests actual macOS microphone authorization, writes
  input buffers to managed CAF staging, and exposes RMS level/voiced frames.
  `ProductionPracticeController` enforces listen → countdown → capture, trailing
  silence, maximum duration, Done, interrupted retention and retry/discard states.
- SQLite now publishes immutable target snapshots without filesystem paths, one
  unique round/take per recording, and ready `take_audio` assets transactionally.
  Checksum manifests recover rename-before-database-commit on launch. No-speech,
  quiet and interrupted takes remain unscored. Lesson deletion now removes dependent
  segment/practice/assessment metadata and all managed B2 audio under one generation fence.
- Normal Shadowing shows a preparation gate instead of preview scores. B3 must create
  real segment revisions before the existing interaction surface can be activated.

Verification:

- `./run.sh test` succeeded: **78 tests in 7 suites, 0 failures**.
  ProductionPersistenceTests passed 17/17.
- A production playback smoke imported real local audio, scheduled a source-frame
  range, paused, sought, resumed and observed completion at the exact end frame.
- Capture-buffer smoke wrote 4,410 real PCM frames to CAF and observed the expected
  RMS/voiced-frame state. Recovery committed two distinct takes/rounds after relaunch,
  preserved complete versus no-speech outcomes, then deleted their files and metadata.
- The built app contains `NSMicrophoneUsageDescription` and the App Sandbox audio-input
  entitlement. Physical microphone capture was not automated or claimed because the
  user authorization prompt was not exercised in this run.
- `./run.sh render` passed and the normal `--route=shadowing` process remained live
  during smoke testing. Orca desktop runtime remained unavailable, so the production
  preparation gate was not visually click-through inspected.

## Backend B3 transcript preparation / first production practice route — 2026-09-11

- YouTube preparation tries creator English WebVTT before automatic WebVTT; only
  absent captions fall back to Apple Speech with on-device recognition required.
  VTT cues become immutable SegmentRevision 1 records with source-audio frame
  ranges. Missing VTT word spans remain explicitly unverified rather than being
  evenly distributed across the cue.
- When Apple Speech permission has already been granted, the importer performs a
  conservative local caption/audio comparison and records an explicit timing-review
  reason only for clear missing-overlap, start-offset or text mismatch evidence.
  This optional check never opens a permission prompt, changes caption timing or
  falls back to cloud recognition.
- Media, captions, segments and immutable revisions publish atomically. Library
  marks a lesson practice-ready only when its current revision and source audio are
  valid. D01b and Start now use that contract; production Shadowing selects a real
  sentence and runs listen → countdown → capture → durable take.
- This is not a B3 completion claim: physical Speech permission/on-device runtime,
  review editor UI, Apple Translation SwiftUI host/live package run, click-word playback
  and full take review remain unverified or unimplemented.

Verification:

- `xcodegen generate` completed after adding production Shadowing files.
- `xcodebuild -project EchoLab.xcodeproj -scheme EchoLab -configuration Debug test`
  succeeded: **86 tests in 7 suites, 0 failures**.
- The new persistence test proves mismatch evidence is stored as review metadata
  without changing source caption timing. The suite does not claim a live Apple
  Speech run or a physical TCC prompt.

## Backend B3 follow-up — IPA, timing revisions and muted YouTube follower — 2026-09-11

- The shipped read-only `ipa.sqlite` bundle is generated by a pinned, SHA-verified
  script from `ipa-dict` US and Britfone UK sources; source/license text is bundled.
  IPA annotations publish atomically with the initial revision, remain offline, and
  preserve UK/US provenance.
- Automatic Apple Translation values persist by immutable revision and never overwrite
  manual overrides. Production Shadowing supplies the system-managed SwiftUI
  `translationTask` host; a real Apple language-package/download consent run is still
  not claimed.
- A timing edit creates revision N+1 only when the caller supplies the current revision
  and preserves its transcript-token identities. It copies automatic/manual annotations;
  historic practice rounds and takes stay linked to their old revision.
- Production Shadowing now embeds a muted YouTube IFrame API follower only for a
  validated stored YouTube source. Native source audio drives sparse seeks/play;
  the view pauses for countdown/capture and returns to the thumbnail if unavailable.
  The restricted WebKit bridge accepts status messages only from its bundled main
  frame. No local video file or YouTube audio is used.

Verification:

- `xcodegen generate` and the full `xcodebuild … test` command above passed.
- Unit coverage verifies UK/US IPA separation, timing mismatch preservation, manual
  annotation survival, and revision publication with stale-writer rejection. It does
  not verify an online YouTube player, exact A/V synchronization, Apple Translation
  download consent, or an interactive timing-editor UI.

## Backend B3 completion pass — production preparation UI — 2026-09-11

- Production Shadowing now projects the current immutable revision's tokens,
  timing-review baseline, IPA annotations and Vietnamese annotation into native
  sentence UI. Missing/malformed annotation payloads remain absent; the UI does
  not invent IPA or a translation.
- Clicking a word previews its verified source-frame range. A word without
  verified timing explicitly falls back to sentence context and remains marked
  for review. The production word sheet uses the same managed source playback.
- The production timing sheet creates `SegmentTimingRevisionDraft` records only;
  the database is still the final validator for source bounds, token identity,
  stale editors and the explicit review-resolution condition. On success the UI
  reloads current data, so new practice targets use revision N+1 while prior
  takes retain their snapshots.
- A finished ready take can now replay only from its expected managed CAF path;
  stored relative paths are not treated as arbitrary URLs.

Verification:

- `xcodegen generate` and
  `xcodebuild -project EchoLab.xcodeproj -scheme EchoLab -configuration Debug -destination 'platform=macOS' test`
  succeeded: **86 tests in 7 suites, 0 failures**.
- The timing-revision persistence test now reads the full production sentence
  projection and verifies it exposes revision N+1 tokens, timing status and
  copied provenance. This is code-level verification only: physical microphone,
  Apple Translation download and a live YouTube embed/sync remain separate
  machine/network checks.

Correction after full Shadowing UI audit:

- Removed the parallel production presentation. Preview and production now share
  `ShadowingPracticeScaffold`, `ShadowingReviewScaffold` and one transport visual
  tree. Production supplies only data/actions to the approved video, transcript,
  sentence, review, Word, Timing, Repeat and microphone components used by the
  migrated D02 route.
- The WebKit YouTube follower remains a media leaf inside the existing 16:9 video
  shell; status and controls stay in the existing strip outside the image.
- Production navigation, window close and app termination now refuse to abandon
  capture/save recovery states. Manual Record is exposed only after a completed
  listen and no longer starts an implicit extra source pass.
- Production repeat/listen, speed, countdown, auto-record, microphone meter,
  replay/A-B and take history use runtime state. Word preview uses its production
  speed binding. Timing uses decoded local-audio samples with explicit loading,
  error and retry states; no production synthetic waveform fallback remains.
  Review shows no fixture assessment or invented score before B4.
- Source seeking is enabled only while the production source schedule is valid,
  clamps below the exclusive end frame and updates controller position. Word,
  timing, take and A/B playback invalidate a paused source-resume token before
  replacing the shared player. Word → Timing starts waveform preparation, and
  interrupted/discarded captures clear `hasListened` so Record requires a new
  complete source listen instead of failing later inside capture.
- The source guard fails if production recreates the D02 source, transcript,
  sentence, review, transport, Word or Timing UI instead of using the shared
  components. `xcodebuild ... build` succeeds and the full native suite passes:
  **87 tests in 7 suites, 0 failures**. Preview renders were inspected at the
  reference, compact, full-review and timing states. This does not claim a live
  network YouTube or physical microphone run.

Sentence parity correction after comparing the live app with Pencil D02d:

- Removed the per-token caution stroke for unverified word timing. The existing
  sentence-level timing notice remains, while ordinary tokens again read as one
  continuous sentence; only selected and playing states receive visual emphasis.
- The live 68-sentence lesson was inspected read-only and had zero IPA annotations,
  although the bundled dictionary contains UK/US entries for the words shown.
  Production Shadowing now runs the existing offline `IPAAnnotationPreparer` once
  when opening an older lesson with missing IPA, then reloads the same immutable
  sentence projections. New imports still prepare IPA during import.
- D00 Word/IPA was rendered after the correction; the needs-timing specimen no
  longer has the unintended amber box. Live-window automation could not complete
  because the Orca runtime stopped with `runtime_unavailable`, so no interactive
  window screenshot is claimed by this pass.

Word-highlight and Library failure correction:

- Production import keeps full helper diagnostics in checkpoints/logging but maps
  HTTP 429, YouTube verification, toolchain, subprocess and persistence failures to
  short learner-facing recovery copy. Failed/preparing lesson placeholders no longer
  appear in the ready lesson grid; the retained import job remains the retry surface.
- Caption preparation now aligns exact normalized caption tokens with observed Apple
  Speech ranges in sequence. It never interpolates missing ranges. Older lessons are
  upgraded on open through immutable timing revisions while verified manual timing and
  annotation provenance survive.
- The shared `EchoWordToken` playing state now applies the approved lavender treatment
  to both the word and IPA, with the existing fill and underline. The 1280×860 reading
  render was inspected with `make` active and matches the D02d state composition.
- `xcodegen generate` and the full native test command pass: **89 tests in 7 suites,
  0 failures**. New coverage locks observed-range alignment/order and proves helper
  diagnostics such as HTTP 429/cookies cannot leak through failure presentation.
