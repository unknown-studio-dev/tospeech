import AppKit
import SwiftUI
@preconcurrency import Translation

private enum ProductionPracticeOverlay: Identifiable {
  case word(String)
  case timing(String?)

  var id: String {
    switch self {
    case .word(let id): "word-\(id)"
    case .timing(let id): "timing-\(id ?? "sentence")"
    }
  }
}

/// Production data/actions plugged into the same D02 composition and shared
/// visual components as the preview route.
struct ProductionShadowingView: View {
  @Bindable var model: ProductionShadowingModel
  @Environment(EchoStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDictation = false
  @State private var videoFollower = YouTubeVideoFollower()
  @State private var translationConfiguration: TranslationSession.Configuration?
  @State private var overlay: ProductionPracticeOverlay?
  @State private var selectedWordID: String?
  @State private var selectedTakeID: UUID?
  @State private var showingReview = false
  @State private var showingRepeatOptions = false
  @State private var showingMicrophone = false
  @State private var wordPreviewSpeed = 0.75
  @State private var showingRecordingManager = false

  var body: some View {
    GeometryReader { geometry in
      practiceContent(
        layout: ShadowingLayout(
          contentWidth: geometry.size.width, contentHeight: geometry.size.height)
      ).frame(width: geometry.size.width)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        HStack(spacing: EchoMetrics.controlGap) {
          if showingReview {
            EchoButton("review.drawer.close", symbol: "xmark", size: .regular) {
              model.stopAuxiliaryPlayback()
              showingReview = false
            }
          } else {
            if selectedTakeID != nil {
              EchoButton("review.drawer.reopen", symbol: "sidebar.right", size: .regular) {
                model.pause()
                showingReview = true
              }
            }
            EchoButton("Tiến bộ", symbol: "chart.line.uptrend.xyaxis", size: .regular) {
              store.navigate(.progress)
            }
            EchoButton("speech.preparation.action", symbol: "waveform", size: .regular) {
              model.presentSpeechPreparation()
            }.disabled(isDictation || !model.canPrepareWordTiming)
            EchoButton("Chỉnh timing", symbol: "slider.horizontal.3", size: .regular) {
              present(.timing(nil))
            }.disabled(isDictation || model.selectedTarget == nil)
          }
          EchoModeSwitch(leadingTitle: "dictation.shadowing", trailingTitle: "dictation.title",
            isOn: practiceModeBinding, identifier: "practice-mode-toggle")
            .disabled(!canSwitchPracticeMode)
        }
        .fixedSize()
        .padding(.vertical, 6)
        .padding(.trailing, 12)
        .accessibilityElement(children: .contain)
      }.sharedBackgroundVisibility(.hidden)
    }
  }

  @ViewBuilder private func practiceContent(layout: ShadowingLayout) -> some View {
    Group {
      if let lesson = presentationLesson,
      let prepared = model.sentence(for: model.selectedTarget),
      let sentence = presentationSentence(prepared)
    {
      if isDictation {
        DictationView(model: model.dictation, layout: layout, lesson: lesson,
          thumbnailURL: model.lesson?.thumbnailURL)
          .task(id: model.preparedSentences.map(\.id)) {
            await model.dictation.activate(model.preparedSentences,
              preferredID: model.selectedTarget?.segmentRevisionID)
          }
          .onChange(of: model.preparedSentences) { _, values in
            model.dictation.refreshAnnotations(values)
          }
          .onDisappear { model.dictation.suspend() }
      } else {
      let storedTake = selectedStoredTake(in: prepared)
      ShadowingPracticeScaffold(
        layout: layout, showsReview: false,
        source: { productionVideo(lesson: lesson) },
        transcript: {
          TranscriptNavigatorView(
            lesson: lesson, contentScale: layout.controlScale,
            selectedSentenceID: sentence.id,
            isCurrentPlaying: model.controller.phase == .listening,
            onSelectSentence: { model.selectAndListen(revisionID: $0) })
        },
        sentence: {
          SentenceView(
            sentence: sentence, selectedWordID: $selectedWordID,
            readingScale: layout.readingScale,
            onReview: currentTakes(prepared).isEmpty ? nil : { openReview(in: prepared) },
            runtime: sentenceRuntime(for: prepared),
            onPreviewLink: { hint, speed in
              model.previewLink(hint, revisionID: prepared.target.segmentRevisionID, speed: speed)
            },
            paceContext: lesson.sentences,
            onWord: { showWord($0, in: prepared) })
        },
        review: { EmptyView() },
        supplementary: { EmptyView() },
        transport: {
          PracticeTransportView(
            onOptions: {
              model.pause()
              showingRepeatOptions = true
            },
            onReview: { openReview(in: prepared) },
            compact: layout.contentWidth < 950, contentScale: layout.controlScale,
            productionModel: model, optionsPresented: $showingRepeatOptions)
        })
      .overlay(alignment: .trailing) {
        if showingReview, let storedTake {
          let take = practiceTake(storedTake, in: prepared)
          ProductionTakeReviewView(
            layout: layout, take: take,
            runtime: ReviewRuntimePresentation(
              history: practiceTakes(in: prepared), selectedTakeID: take.id,
              onSelectTake: { selectedTakeID = UUID(uuidString: $0) },
              onPreviewOriginal: { model.previewOriginal(storedTake) },
              onPreviewTake: { model.replay(storedTake) },
              onCompare: { model.compare(storedTake) }, assessmentUnavailableText: nil,
              matchingService: model.matchingService, onMatch: { model.match(storedTake) },
              assessmentService: model.assessmentService,
              onAssess: { model.assess(storedTake, preferences: store.preferences) },
              onReplayDetail: { model.replayDetail(storedTake, start: $0, end: $1) },
              onReferenceDetail: { model.previewOriginalDetail(storedTake, start: $0, end: $1) },
              onCompareDetail: { model.compareDetail(storedTake, source: $0, recorded: $1) },
              onStop: { model.stopAuxiliaryPlayback() }, player: model.reviewPlayer,
              sourceAudioURL: model.reviewSourceURL(storedTake),
              onCompareTogether: { model.compareTogether(storedTake) },
              sourceAsset: model.reviewSourceAsset(storedTake),
              takeAssets: currentTakes(prepared).compactMap { model.reviewTakeAsset($0) },
              onManageRecordings: { showingRecordingManager = true }),
            onBack: { showingReview = false },
            onRecordAgain: { showingReview = false; model.listenThenRecord() },
            source: { productionVideo(lesson: lesson) }, presentation: .drawer)
            .id(take.id)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .task(id: "\(take.id):\(store.preferences.productionAssessmentEngine?.rawValue ?? "off"):\(store.preferences.accent.rawValue)") {
              await model.assessIfNeeded(storedTake, preferences: store.preferences)
            }
        }
      }
      .animation(EchoMotion.content(reduceMotion: reduceMotion), value: showingReview)
      .sheet(item: $overlay) { item in
        Group {
          switch item {
          case .word(let id):
            if let token = prepared.tokens.first(where: { $0.id == id }) {
              ProductionWordPronunciationSheet(
                sentence: sentence, token: token,
                onPreview: { model.preview(token, speed: wordPreviewSpeed) },
                onPrepareReference: { model.prepareForReferencePlayback() },
                onStopSource: { model.stopAuxiliaryPlayback() },
                onEditTiming: { present(.timing(id)) },
                onRemoveWord: {
                  Task { if await model.removeWord(token.id, from: prepared) { overlay = nil } }
                },
                onClose: { overlay = nil },
                runtime: WordPronunciationRuntime(
                  previewSpeed: $wordPreviewSpeed,
                  interactionDisabled: model.controller.phase == .countdown || model.controller.phase.isCapture
                    || model.controller.phase == .saving
                    || model.controller.phase == .saveFailed))
            }
          case .timing(let wordID):
            ProductionTimingEditorSheet(
              lesson: lesson, sentence: sentence, wordID: wordID,
              onPreview: { span, _ in
                model.preview(span, speed: wordPreviewSpeed)
              },
              onSave: { draft in await model.publishTimingDraft(draft, from: prepared) },
              waveformSamples: model.waveformSamples,
              isPreparingWaveform: model.isPreparingWaveform,
              waveformError: model.waveformError,
              onRetryWaveform: { Task { await model.retryWaveform() } },
              onClose: { overlay = nil })
          }
        }
        .environment(\.locale, store.preferences.language.locale)
      }
      .sheet(isPresented: $showingMicrophone) {
          MicrophonePreviewSheet(runtime: MicrophoneRuntimeActions(
            permissionDenied: model.controller.permission == .denied
              || model.controller.permission == .restricted,
            permissionGranted: model.controller.permission == .granted,
            onListenOnly: {
              showingMicrophone = false
            },
            onRetry: {
              model.checkMicrophonePermission()
            },
            onOpenSettings: {
              guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
              else { return }
              NSWorkspace.shared.open(url)
            }))
      }
      .sheet(isPresented: $showingRecordingManager) {
        RecordingManagerSheet(
          recordings: model.allPracticeTakes(),
          loadByteCounts: { await model.recordingByteCounts() },
          delete: { try await model.deleteRecordings($0) },
          close: { showingRecordingManager = false })
          .environment(\.locale, store.preferences.language.locale)
      }
      }
      } else if model.isLoading || (model.lesson != nil && model.error == nil && model.preparedSentences.isEmpty) {
        EchoLoading(title: "production.practice.preparing")
      } else {
        EchoEmptyState(
          title: "Choose a prepared lesson",
          message: "Import a lesson with an English transcript before practicing.",
          symbol: "headphones")
      }
    }
    .echoContentReveal(value: [isDictation, showingReview, model.selectedTarget != nil],
      enabled: !model.controller.phase.isCapture
        && ![.listening, .countdown, .saving, .saveFailed].contains(model.controller.phase)
        && !model.dictation.isPlaying && model.reviewPlayer.state != .playing)
    .sheet(isPresented: $model.showingSpeechPreparation, onDismiss: model.dismissSpeechPreparation) {
      SpeechPreparationSheet(
        isPreparing: model.isPreparingWordTiming, error: model.speechPreparationError,
        onContinue: model.startWordTimingPreparation, onClose: model.dismissSpeechPreparation)
        .environment(store)
        .environment(\.locale, store.preferences.language.locale)
    }
    .task {
      wordPreviewSpeed = store.preferences.speed
      model.applyPreferences(store.preferences)
      await model.load()
    }
    .task(id: model.lesson?.id) {
      videoFollower.configure(
        source: !isDictation && store.preferences.video ? model.lesson?.youtubeVisualSource : nil)
      synchronizeVideo()
    }
    // Keyed separately from the video task: a native-language change must
    // reach Apple Translation without reloading the YouTube frame.
    .task(id: translationTaskKey) {
      translationConfiguration = model.lesson.flatMap { _ in
        translationLanguage.isNone ? nil : AppleTranslationPreparer.configuration(for: translationLanguage)
      }
    }
    .translationTask(translationConfiguration) { session in
      guard let lessonID = model.lesson?.id else { return }
      await model.prepareTranslation(session: session, lessonID: lessonID, language: translationLanguage)
    }
    .onChange(of: scenePhase) { _, phase in
      if isDictation && phase != .active { model.dictation.suspend() }
    }
    .onChange(of: model.controller.sourcePosition) { _, _ in synchronizeVideo() }
    .onChange(of: model.controller.phase) { _, _ in synchronizeVideo() }
    .onChange(of: model.controller.lastTake?.id) { _, _ in
      Task { await model.refreshTakes() }
    }
    .onChange(of: model.controller.error) { _, error in
      if error == .microphoneDenied { showingMicrophone = true }
    }
    .onChange(of: store.preferences.video) { _, enabled in
      videoFollower.configure(source: !isDictation && enabled ? model.lesson?.youtubeVisualSource : nil)
      synchronizeVideo()
    }
    .onChange(of: store.preferences) { _, preferences in
      model.applyPreferences(preferences)
    }
    .onChange(of: model.selectedTarget?.segmentRevisionID) {
      selectedWordID = nil
      selectedTakeID = nil
      showingReview = false
    }
    .overlay(alignment: .bottom) {
      if let error = model.error ?? model.controller.error.map(\.presentationCopy) {
        EchoNotice(copy: error, error: true).padding(24)
      }
    }
  }

  private var translationLanguage: TranslationLanguage {
    TranslationLanguage(identifier: store.preferences.translationLanguage)
  }

  private var translationTaskKey: String {
    "\(model.lesson?.id.uuidString ?? "")/\(store.preferences.translationLanguage)"
  }

  private var presentationLesson: Lesson? {
    guard let source = model.lesson else { return nil }
    let sentences = model.lessonSentences
    let duration = source.duration
      ?? sentences.map(\.span.end).max()
      ?? 0
    return Lesson(
      id: source.id.uuidString, title: source.title, author: source.author ?? "",
      thumbnail: "", duration: duration, accent: store.preferences.accent,
      sourceURL: source.youtubeVisualSource?.sourceURL.absoluteString,
      createdAt: source.createdAt, sentences: sentences)
  }

  private func presentationSentence(_ prepared: ProductionPreparedSentence) -> LessonSentence? {
    guard let index = model.preparedSentences.firstIndex(where: { $0.id == prepared.id }) else {
      return nil
    }
    return prepared.lessonSentence(number: index + 1)
  }

  private func currentTakes(_ sentence: ProductionPreparedSentence) -> [ProductionStoredTake] {
    var values = model.takes(for: sentence)
    if let latest = model.controller.lastTake,
      latest.segmentRevisionID == sentence.target.segmentRevisionID,
      !values.contains(where: { $0.id == latest.id })
    {
      values.append(latest)
    }
    return values
  }

  private func practiceTakes(in sentence: ProductionPreparedSentence) -> [PracticeTake] {
    currentTakes(sentence).map { practiceTake($0, in: sentence) }
  }

  private func practiceTake(
    _ take: ProductionStoredTake, in sentence: ProductionPreparedSentence
  ) -> PracticeTake {
    let all = currentTakes(sentence)
    let number = all.firstIndex(where: { $0.id == take.id }).map { $0 + 1 } ?? all.count
    let sentenceNumber = model.preparedSentences.firstIndex(where: { $0.id == sentence.id })
      .map { $0 + 1 } ?? 1
    return (model.savedTakeSentences[take.id] ?? sentence)
      .practiceTake(take, number: number, sentenceNumber: sentenceNumber)
  }

  private func selectedStoredTake(
    in sentence: ProductionPreparedSentence
  ) -> ProductionStoredTake? {
    let values = currentTakes(sentence)
    return values.first(where: { $0.id == selectedTakeID }) ?? values.last
  }

  private func openReview(in sentence: ProductionPreparedSentence) {
    guard let take = currentTakes(sentence).last else { return }
    model.pause()
    selectedTakeID = take.id
    showingReview = true
  }

  private func reviewSentenceRuntime(
    for sentence: ProductionPreparedSentence, take: ProductionStoredTake
  ) -> SentenceRuntimePresentation {
    var runtime = sentenceRuntime(for: sentence)
    if take.segmentRevisionID != sentence.target.segmentRevisionID { runtime.interactionDisabled = true }
    return runtime
  }

  private func sentenceRuntime(
    for sentence: ProductionPreparedSentence
  ) -> SentenceRuntimePresentation {
    let storedTake = currentTakes(sentence).last
    let take = storedTake.map { practiceTake($0, in: sentence) }
    return SentenceRuntimePresentation(
      playingWordID: playingWordID(in: sentence),
      interactionDisabled: model.controller.phase == .countdown || model.controller.phase.isCapture
        || model.controller.phase == .saving || model.controller.phase == .saveFailed,
      hasCurrentTake: !currentTakes(sentence).isEmpty,
      takeCount: currentTakes(sentence).count,
      sentenceCount: model.preparedSentences.count,
      translationPlaceholder: model.isPreparingTranslation
        ? "Đang chuẩn bị bản dịch…"
        : "Chưa có bản dịch · mở chỉnh timing để bổ sung.",
      currentTake: take,
      feedbackActions: storedTake.map { stored in
        InlineFeedbackRuntimeActions(
          actionsBlocked: model.controller.phase.isCapture
            || [.countdown, .saving, .saveFailed].contains(model.controller.phase),
          onCheckMicrophone: {
            model.checkMicrophonePermission()
            showingMicrophone = true
          },
          onCompare: { model.compare(stored) },
          onRetry: {
            if let job = model.assessmentService?.history(takeID: stored.id).last {
              Task { await model.assessmentService?.retry(job) }
            } else if let job = model.matchingService?.history(takeID: stored.id).last {
              Task { await model.matchingService?.retry(job) }
            } else { model.match(stored) }
          },
          onReview: {
            selectedTakeID = stored.id
            showingReview = true
          }, matchingState: matchingState(stored), matchingMessage: matchingMessage(stored),
          errorWord: model.assessmentService?.history(takeID: stored.id).last?.errorWord)
      })
  }

  private func matchingState(_ take: ProductionStoredTake) -> InlineFeedbackState? {
    if [.complete, .earlyStop].contains(take.outcome),
      let job = model.assessmentService?.history(takeID: take.id).last {
      switch job.status {
      case .queued, .running: return .pending
      case .complete: return .complete
      case .failed: return .failed
      case .unrecognized: return .unscored
      }
    }
    guard [.complete, .earlyStop].contains(take.outcome),
      let job = model.matchingService?.history(takeID: take.id).last else { return nil }
    switch job.status {
    case .queued, .running: return .pending
    case .complete: return .complete
    case .failed: return .failed
    case .unrecognized: return .unscored
    }
  }

  private func matchingMessage(_ take: ProductionStoredTake) -> String? {
    if [.complete, .earlyStop].contains(take.outcome),
      let job = model.assessmentService?.history(takeID: take.id).last {
      return job.inlineMessageKey
    }
    guard [.complete, .earlyStop].contains(take.outcome),
      let job = model.matchingService?.history(takeID: take.id).last else { return nil }
    switch job.status {
    case .queued: return "matching.queued"
    case .running: return "matching.running"
    case .complete: return "matching.ready"
    case .failed: return "matching.failed_short"
    case .unrecognized: return "matching.unrecognized"
    }
  }

  private func productionVideo(lesson: Lesson) -> some View {
    VideoPreviewView(
      lesson: lesson, onEdit: { present(.timing(nil)) }, isProductionMode: true,
      productionFollower: model.lesson?.youtubeVisualSource == nil ? nil : videoFollower,
      productionThumbnailURL: model.lesson?.thumbnailURL,
      hasProductionVideo: model.lesson?.youtubeVisualSource != nil,
      onRetryProductionVideo: { videoFollower.retry() },
      onToggleProductionVideo: { store.preferences.video.toggle() })
  }

  private func playingWordID(in sentence: ProductionPreparedSentence) -> String? {
    guard model.controller.phase == .listening || model.controller.phase == .paused else { return nil }
    guard let frame = Int(exactly: (model.controller.sourcePosition * Double(sentence.target.sampleRate)).rounded()) else { return nil }
    return ProductionWordTiming.playingWordID(at: frame, tokens: sentence.tokens, in: sentence.target)
  }

  private func showWord(_ id: String, in sentence: ProductionPreparedSentence) {
    guard !model.controller.phase.isCapture, model.controller.phase != .saving,
      model.controller.phase != .saveFailed,
      let token = sentence.tokens.first(where: { $0.id == id })
    else { return }
    selectedWordID = id
    model.preview(token, speed: wordPreviewSpeed)
    overlay = .word(id)
  }

  private func present(_ value: ProductionPracticeOverlay) {
    guard !model.controller.phase.isCapture, model.controller.phase != .saving,
      model.controller.phase != .saveFailed
    else { return }
    model.pause()
    overlay = value
    if case .timing = value { Task { await model.prepareWaveform() } }
  }

  private var practiceModeBinding: Binding<Bool> {
    Binding(get: { isDictation }, set: { switchMode($0) })
  }

  private var canSwitchPracticeMode: Bool {
    model.selectedTarget != nil && !model.controller.phase.isCapture
      && ![.countdown, .saving, .saveFailed].contains(model.controller.phase)
  }

  private func switchMode(_ enabled: Bool) {
    guard enabled != isDictation, !model.controller.phase.isCapture,
      ![.countdown, .saving, .saveFailed].contains(model.controller.phase) else { return }
    model.pause()
    model.stopAuxiliaryPlayback()
    model.dictation.suspend()
    if !enabled, let target = model.dictation.sentence?.target { model.select(target) }
    showingReview = false
    overlay = nil
    isDictation = enabled
    model.dictation.speed = store.preferences.speed
    videoFollower.configure(source: !enabled && store.preferences.video ? model.lesson?.youtubeVisualSource : nil)
    synchronizeVideo()
  }

  private func synchronizeVideo() {
    guard !isDictation else { return }
    videoFollower.follow(
      sourceSeconds: model.controller.sourcePosition,
      isNativeAudioPlaying: store.preferences.video && model.controller.phase == .listening)
  }
}

/// Explicit local alignment of the existing transcript, preserving manual timing and takes.
struct SpeechPreparationSheet: View {
  @Environment(EchoStore.self) private var store
  var isPreparing: Bool
  var error: EchoCopy?
  var onContinue: () -> Void
  var onClose: () -> Void

  var body: some View {
    EchoSheet(title: "speech.preparation.title", subtitle: "speech.preparation.subtitle", width: 560, close: onClose) {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "waveform").font(EchoFont.body(size: 36)).foregroundStyle(EchoTheme.muted)
        EchoLocalizedText("speech.preparation.explanation")
          .font(EchoFont.body(size: 14)).lineSpacing(5)
        if isPreparing { EchoLoading(title: "speech.preparation.busy") }
        if let error { EchoNotice(copy: error, error: true) }
        HStack {
          EchoButton(isPreparing ? "Cancel" : "speech.preparation.skip", action: onClose)
          Spacer()
          EchoButton(error == nil ? "Continue" : "Retry", kind: .primary, action: onContinue)
            .disabled(isPreparing)
        }
      }
    }
    .environment(\.locale, store.preferences.language.locale)
  }
}
