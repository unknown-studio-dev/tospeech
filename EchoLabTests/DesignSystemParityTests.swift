import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EchoLab

@MainActor @Suite(.serialized)
struct DesignSystemParityTests {
  @Test func settingsColumnsMatchApprovedReferenceWidths() {
    #expect(SettingsLayoutMetrics.firstColumn(width: 1176, composition: .general) == 712)
    #expect(SettingsLayoutMetrics.firstColumn(width: 1536, composition: .general) == 936)
    #expect(SettingsLayoutMetrics.firstColumn(width: 1176, composition: .recording) == 400)
    #expect(SettingsLayoutMetrics.firstColumn(width: 1536, composition: .recording) == 480)
    for width: CGFloat in [736, 900, 1015] {
      #expect(SettingsLayoutMetrics.firstColumn(width: width, composition: .general) == width)
      #expect(SettingsLayoutMetrics.firstColumn(width: width, composition: .recording) == width)
    }
  }

  @Test func settingsColumnsStackWithoutShrinkingContent() {
    for width: CGFloat in [736, 1176, 1536] {
      let host = NSHostingView(
        rootView: SettingsColumns(composition: .general) {
          Color.clear.frame(height: 180)
          Color.clear.frame(height: 220)
        }.frame(width: width))
      #expect(host.fittingSize == CGSize(width: width, height: width < 1016 ? 424 : 220))
    }
  }

  @Test func intrinsicSettingsTabsDoNotStretchOrChangeHeight() {
    for selected in [0, 1] {
      let host = NSHostingView(
        rootView: EchoSegmented(
          selection: .constant(selected),
          options: [(0, "Chung"), (1, "Ghi âm & models")], fillsWidth: false,
          labelSize: 14, horizontalPadding: 20))
      #expect(host.fittingSize.height == 36)
      #expect(host.fittingSize.width > 200 && host.fittingSize.width < 300)
    }
  }

  @Test func inputErrorOverridesFocusWithoutAnotherRing() {
    let resting = EchoFieldBorder()
    #expect(resting.color == EchoTheme.border)
    #expect(resting.lineWidth == 1)
    let focused = EchoFieldBorder(focused: true)
    #expect(focused.color == EchoTheme.focus)
    #expect(focused.lineWidth == 2)
    for focus in [false, true] {
      let invalid = EchoFieldBorder(state: .error("Invalid link"), focused: focus)
      #expect(invalid.color == EchoTheme.danger)
      #expect(invalid.lineWidth == (focus ? 2 : 1))
    }
    #expect(EchoFieldBorder(state: .success("Saved"), focused: true).color == EchoTheme.focus)
    #expect(EchoFieldBorder(state: .success("Saved")).color == EchoTheme.border)
  }

  @Test func disabledInputDoesNotShowFocus() {
    for border in [
      EchoFieldBorder(focused: true, enabled: false),
      EchoFieldBorder(state: .disabled("Unavailable"), focused: true),
    ] {
      #expect(border.color == EchoTheme.border)
      #expect(border.lineWidth == 1)
    }
  }

  @Test func fieldBorderNeverChangesLayoutSize() {
    for state: EchoControlState in [
      .idle, .loading("Checking"), .error("Invalid"),
      .success("Saved"), .disabled("Unavailable"),
    ] {
      for focus in [false, true] {
        let host = NSHostingView(
          rootView: Color.clear.frame(width: 320, height: 32)
            .overlay(EchoFieldBorder(state: state, focused: focus)))
        #expect(host.fittingSize == CGSize(width: 320, height: 32))
      }
    }
  }

  @Test func baseControlsUsePencil32PointSize() {
    #expect(EchoButton("Save") {}.size.height == 32)
    #expect(EchoTextField(label: "Title", text: .constant("")).size.height == 32)
    #expect(
      EchoSelect(label: "Accent", selection: .constant("uk"), options: [("uk", "UK")]).size.height
        == 32)
    #expect(EchoSearchField(placeholder: "Search", text: .constant("")).size.height == 32)
    #expect(EchoControlSize.regular.height == 36)
    #expect(EchoControlSize.prominent.height == 44)
    #expect(EchoControlSize.practice.height == 40)
  }

  @Test func d00MenuAndSupportingComponentsHaveStableGeometry() {
    for selected in [false, true] {
      for highlighted in [false, true] {
        let row = NSHostingView(
          rootView: EchoSelectOptionLabel(
            title: "English (UK)", selected: selected, highlighted: highlighted
          ).frame(width: 300))
        #expect(row.fittingSize == CGSize(width: 300, height: 32))
      }
    }
    let skeleton = NSHostingView(rootView: EchoContentSkeleton().frame(width: 772))
    #expect(skeleton.fittingSize == CGSize(width: 772, height: 82))
    let sheet = NSHostingView(
      rootView: EchoUnsavedSheet(onKeepEditing: {}, onDiscard: {}, onSave: {}))
    #expect(sheet.fittingSize == CGSize(width: 620, height: 213))
    let slider = NSHostingView(
      rootView: EchoSlider(
        value: .constant(100), range: 80...160, step: 10, label: "Cỡ chữ", valueLabel: "100%",
        previewFocused: true
      ).frame(width: 192))
    #expect(slider.fittingSize == CGSize(width: 192, height: 24))
  }

  @Test func importPresentationSheetsMatchApprovedPencilGeometry() {
    let progress = NSHostingView(
      rootView: ImportProgressSheet(
        presentation: ImportPreparationFixtures.progress,
        onContinueBrowsing: {}, onCancelImport: {}))
    let ready = NSHostingView(
      rootView: ImportReadySheet(
        presentation: ImportPreparationFixtures.ready,
        onStartPracticing: {}, onBackToLibrary: {}))

    #expect(progress.fittingSize == ImportProgressSheet.size)
    #expect(ready.fittingSize == ImportReadySheet.size)
  }

  @Test func importProgressFixtureKeepsFourExplicitCheckpointStates() {
    let presentation = ImportPreparationFixtures.progress
    #expect(presentation.steps.count == 4)
    #expect(presentation.currentStep == 3)
    #expect(presentation.totalSteps == 4)
    #expect(presentation.fractionCompleted == 0.75)
    #expect(presentation.steps.map(\.state) == [.completed, .completed, .current, .pending])
  }

  @Test func productionImportCheckpointMapsOnlyToPersistedPreparationStages() throws {
    let phases: [(ProductionImportPhase, Int, [ImportPreparationStepState])] = [
      (.resolving, 1, [.current, .pending, .pending, .pending]),
      (.downloadingAudio, 1, [.current, .pending, .pending, .pending]),
      (.probing, 1, [.current, .pending, .pending, .pending]),
      (.fetchingCaptions, 2, [.completed, .current, .pending, .pending]),
      (.preparingSpeechModel, 2, [.completed, .current, .pending, .pending]),
      (.checkingTiming, 3, [.completed, .completed, .current, .pending]),
      (.preparingTranscript, 3, [.completed, .completed, .current, .pending]),
      (.publishing, 4, [.completed, .completed, .completed, .current]),
    ]

    for (phase, currentStep, states) in phases {
      let presentation = try #require(ProductionImportPresentationMapper.progress(for: job(phase)))
      #expect(presentation.currentStep == currentStep)
      #expect(presentation.totalSteps == 4)
      #expect(presentation.fractionCompleted == Double(currentStep) / 4)
      #expect(presentation.steps.map(\.state) == states)
    }

    for terminal in [ProductionImportPhase.ready, .failed, .cancelled] {
      #expect(ProductionImportPresentationMapper.progress(for: job(terminal)) == nil)
    }
  }

  @Test func transcriptionSubProgressAdvancesTheBarWithinTheTranscriptStep() throws {
    // The transcript step is index 2 of 4; sub-progress fills the bar from the
    // step's start (0.5) toward its completion (0.75) instead of sitting frozen.
    let start = try #require(
      ProductionImportPresentationMapper.progress(for: job(.preparingTranscript), subProgress: 0))
    #expect(start.fractionCompleted == 0.5)
    let mid = try #require(
      ProductionImportPresentationMapper.progress(for: job(.preparingTranscript), subProgress: 0.5))
    #expect(mid.fractionCompleted == 0.625)
    let full = try #require(
      ProductionImportPresentationMapper.progress(for: job(.preparingTranscript), subProgress: 1))
    #expect(full.fractionCompleted == 0.75)
    // The step indicator stays "current" throughout; only the bar moves.
    #expect(mid.steps.map(\.state) == [.completed, .completed, .current, .pending])
  }

  @Test func transcriptionSubProgressIsClampedAndNilFallsBackToStepTicks() throws {
    let clampedLow = try #require(
      ProductionImportPresentationMapper.progress(
        for: job(.preparingTranscript), subProgress: -3))
    #expect(clampedLow.fractionCompleted == 0.5)
    let clampedHigh = try #require(
      ProductionImportPresentationMapper.progress(
        for: job(.preparingTranscript), subProgress: 4))
    #expect(clampedHigh.fractionCompleted == 0.75)
    // Without sub-progress the mapper keeps the original per-step fraction.
    let noSub = try #require(
      ProductionImportPresentationMapper.progress(for: job(.preparingTranscript)))
    #expect(noSub.fractionCompleted == 0.75)
  }

  @Test func resolvedIPAFallsBackToTheOtherAccentAndMarksIt() {
    let both = LessonWord(id: "w0", text: "world", ipaUK: "wɜːld", ipaUS: "wɝld")
    #expect(both.resolvedIPA(for: .uk) == ResolvedIPA(text: "wɜːld", fallbackAccent: nil))
    #expect(both.resolvedIPA(for: .us) == ResolvedIPA(text: "wɝld", fallbackAccent: nil))

    // Proper noun absent from the British dictionary but present in US.
    let ukMissing = LessonWord(id: "w1", text: "Howard", ipaUK: nil, ipaUS: "ˈhaʊɚd")
    #expect(ukMissing.resolvedIPA(for: .uk) == ResolvedIPA(text: "ˈhaʊɚd", fallbackAccent: .us))
    #expect(ukMissing.resolvedIPA(for: .us) == ResolvedIPA(text: "ˈhaʊɚd", fallbackAccent: nil))

    // Empty string counts as missing, not as a pronunciation.
    let emptyUK = LessonWord(id: "w2", text: "Ashley", ipaUK: "", ipaUS: "ˈæʃli")
    #expect(emptyUK.resolvedIPA(for: .uk) == ResolvedIPA(text: "ˈæʃli", fallbackAccent: .us))

    // Absent from both dictionaries: nothing to show.
    let neither = LessonWord(id: "w3", text: "Chuzzlewit", ipaUK: nil, ipaUS: nil)
    #expect(neither.resolvedIPA(for: .uk) == nil)
    #expect(neither.resolvedIPA(for: .us) == nil)
  }

  @Test func ipaNotationIsConsistentAndPunctuationHasNoPronunciationRow() {
    for raw in ["həˈləʊ", "/həˈləʊ/", " [həˈləʊ] ", "//həˈləʊ//"] {
      #expect(IPAFormatting.display(raw) == "/həˈləʊ/")
    }
    #expect(IPAFormatting.display(" / / ") == nil)
    for punctuation in [".", ",", "?!", "…", "—", "“", " ” "] {
      #expect(!IPAFormatting.isPronounceable(punctuation))
      let shown = NSHostingView(rootView: EchoWordToken(word: punctuation, ipa: nil) {})
      let hidden = NSHostingView(rootView: EchoWordToken(word: punctuation, ipa: nil, showIPA: false) {})
      #expect(shown.fittingSize == hidden.fittingSize)
    }
    for word in ["Hello,", "don't", "2026"] {
      #expect(IPAFormatting.isPronounceable(word))
    }
  }

  @Test func d00WordSelectionNeverChangesGeometry() {
    let sizes = EchoWordState.allCases.map { state in
      NSHostingView(
        rootView: EchoWordToken(word: "thought", ipa: "/θɔːt/", state: state, specimenWidth: 220) {}
      ).fittingSize
    }
    #expect(sizes.allSatisfy { $0 == sizes.first })
    #expect(sizes.allSatisfy { $0.width == 220 })
  }

  private func job(_ phase: ProductionImportPhase) -> ProductionImportJob {
    ProductionImportJob(
      id: UUID(), lessonID: UUID(), title: "Imported lesson", phase: phase,
      runToken: UUID(), expectedGeneration: 1, error: nil,
      createdAt: .distantPast, updatedAt: .distantPast)
  }

  @Test func sharedRowStatesKeepTheSameGeometry() {
    for selected in [false, true] {
      for navigation in [false, true] {
        let row = NSHostingView(
          rootView: EchoRowButton(selected: selected, navigation: navigation, action: {}) {
            Text("Shadowing")
          }.frame(width: 220))
        #expect(row.fittingSize == CGSize(width: 220, height: 40))
      }
    }
  }

  @Test func numberFieldRejectsPartialOrNonfiniteDrafts() {
    let english = Locale(identifier: "en_US")
    for invalid in ["", "-", "1.2 seconds", "nan", "inf", "1e999", "1.2.3"] {
      #expect(EchoNumberField.parse(invalid, locale: english) == nil)
    }
    #expect(EchoNumberField.parse(" 12.34 ", locale: english) == 12.34)
    #expect(EchoNumberField.parse("12,34", locale: Locale(identifier: "de_DE")) == 12.34)
    #expect(EchoNumberField.parse("0", locale: english) == 0)
  }

  @Test func optionalLearningPreferencesDoNotInventAnswersForOldSnapshots() throws {
    var preferences = try JSONDecoder().decode(
      Preferences.self, from: JSONEncoder().encode(Preferences()))
    #expect(preferences.learningGoal == nil)
    #expect(preferences.selfAssessedLevel == nil)
    preferences.learningGoal = .speaking
    preferences.selfAssessedLevel = .basicConversation
    let restored = try JSONDecoder().decode(
      Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.learningGoal == .speaking)
    #expect(restored.selfAssessedLevel == .basicConversation)
  }

  @Test func repeatOptionsKeepTheirPopoverSizeForEverySpeed() {
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    for expanded in [false, true] {
      for speed in PracticeOptions.speeds {
        store.preferences.speed = speed
        let host = NSHostingView(
          rootView: RepeatOptionsView(onClose: {}, initiallyExpanded: expanded).environment(store))
        #expect(host.fittingSize == CGSize(width: 420, height: expanded ? 480 : 380))
      }
    }
  }

  @Test func playbackSpeedButtonsPreserveSingleLineIntrinsicSize() {
    for speed in PracticeOptions.speeds {
      let title = "\(EchoFormat.decimal(speed))×"
      let natural = NSHostingView(rootView: EchoButton(title) {})
      let compressed = NSHostingView(rootView: EchoButton(title) {}.frame(width: 35))
      #expect(natural.fittingSize.height == 32)
      #expect(compressed.fittingSize.height == 32)
      #expect(natural.fittingSize.width > 35)
    }
  }

  @Test func referenceGeometryMatchesD02() {
    let layout = ShadowingLayout(contentWidth: 1032)
    #expect(layout.videoWidth == 576)
    #expect(layout.videoHeight == 324)
    #expect(layout.transcriptWidth == 432)
    #expect(layout.mediaRowHeight == 364)
    #expect(ShadowingLayout.transportHeight == 108)
  }

  @Test func largeWindowPrioritizesReadingWithoutZoomingAllControls() {
    let layout = ShadowingLayout(contentWidth: 1552, contentHeight: 1072)
    #expect(abs(34 * layout.readingScale - 44) < 0.001)
    #expect(layout.controlScale <= 1.2)
    #expect(layout.videoWidth + layout.transcriptWidth + 24 == 1552)
    #expect(abs(layout.videoWidth / layout.videoHeight - 16 / 9) < 0.001)
    let wide = ShadowingLayout(contentWidth: 2312, contentHeight: 1032)
    #expect(wide.mediaRowHeight < 550)
    #expect(wide.readingScale <= 44 / 34)
  }

  @Test func resizingPreservesVideoAspectRatio() {
    for width: CGFloat in [752, 900, 1032, 1088] {
      let layout = ShadowingLayout(contentWidth: width)
      #expect(abs(layout.videoWidth / layout.videoHeight - 16 / 9) < 0.001)
      #expect(
        abs(layout.videoWidth + layout.transcriptWidth + ShadowingLayout.columnGap - width) < 0.001)
    }
  }

  @Test func segmentedAndWordSheetHaveReferenceSize() throws {
    let segmented = NSHostingView(
      rootView: EchoSegmented(selection: .constant("uk"), options: [("uk", "UK"), ("us", "US")])
        .frame(width: 240))
    #expect(segmented.fittingSize.height == 36)
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    let sentence = try #require(store.selectedSentence)
    let word = try #require(sentence.words.first)
    let sheet = NSHostingView(
      rootView: WordPronunciationView(
        sentence: sentence, wordID: word.id, onEditTiming: { _ in }, onClose: {}
      ).environment(store))
    #expect(sheet.fittingSize == CGSize(width: 520, height: 526))
  }

  @Test func seekingClampsWithoutStartingPlaybackOrCapture() throws {
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    let range = try #require(store.practice.sourceSeekRange)
    store.practice.seekSource(to: range.end + 50)
    #expect(store.practice.sourcePosition == range.end)
    #expect(store.practice.phase == .idle)
    #expect(!store.practice.hasListened)
    store.practice.seekSource(to: range.start - 50)
    #expect(store.practice.sourcePosition == range.start)
    store.practice.seekSource(to: .nan)
    #expect(store.practice.sourcePosition == range.start)
    store.practice.phase = .recording
    store.practice.seekSource(to: range.end)
    #expect(store.practice.sourcePosition == range.start)
  }

  @Test func activeSeekUsesSourceTimeNotWallClock() throws {
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    store.preferences.speed = 0.5
    store.practice.playSentence()
    let range = try #require(store.practice.sourceSeekRange)
    let middle = range.start + range.duration / 2
    store.practice.seekSource(to: middle)
    #expect(store.practice.sourcePosition == middle)
    #expect(abs(store.practice.remaining - range.duration) < 0.001)
    #expect(!store.practice.hasListened)
    store.practice.interrupt()
  }

  @Test func choosingLocalAudioAfterYouTubeKeepsTheFileSelected() {
    var selection = ProductionImportSelection()
    selection.updateYouTubeInput("https://www.youtube.com/watch?v=jNQXAC9IVRw")
    #expect(selection.youtubeURL != nil)

    let file = URL(fileURLWithPath: "/tmp/source.wav")
    selection.chooseLocalFile(file)
    selection.updateYouTubeInput("")

    #expect(selection.youtubeInput.isEmpty)
    #expect(selection.youtubeURL == nil)
    #expect(selection.localURL == file)

    selection.updateYouTubeInput("https://youtu.be/jNQXAC9IVRw")
    #expect(selection.localURL == nil)
  }
}
