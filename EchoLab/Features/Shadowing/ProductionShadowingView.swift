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
  @State private var videoFollower = YouTubeVideoFollower()
  @State private var translationConfiguration: TranslationSession.Configuration?
  @State private var overlay: ProductionPracticeOverlay?
  @State private var selectedWordID: String?
  @State private var selectedTakeID: UUID?
  @State private var showingReview = false
  @State private var showingRepeatOptions = false
  @State private var showingMicrophone = false
  @State private var wordPreviewSpeed = 0.75

  var body: some View {
    GeometryReader { geometry in
      practiceContent(
        layout: ShadowingLayout(
          contentWidth: geometry.size.width, contentHeight: geometry.size.height)
      ).frame(width: geometry.size.width)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        EchoButton("Tiến bộ", symbol: "chart.line.uptrend.xyaxis", size: .regular) {
          store.navigate(.progress)
        }
        EchoButton("Chỉnh timing", symbol: "slider.horizontal.3", size: .regular) {
          present(.timing(nil))
        }.disabled(model.selectedTarget == nil)
      }
    }
  }

  @ViewBuilder private func practiceContent(layout: ShadowingLayout) -> some View {
    Group {
      if let lesson = presentationLesson,
      let prepared = model.sentence(for: model.selectedTarget),
      let sentence = presentationSentence(prepared)
    {
      let storedTake = showingReview ? selectedStoredTake(in: prepared) : nil
      ShadowingPracticeScaffold(
        layout: layout, showsReview: storedTake != nil,
        source: { productionVideo(lesson: lesson) },
        transcript: {
          TranscriptNavigatorView(
            lesson: lesson, contentScale: layout.controlScale,
            selectedSentenceID: sentence.id,
            onSelectSentence: { model.selectAndListen(revisionID: $0) })
        },
        sentence: {
          SentenceView(
            sentence: sentence, selectedWordID: $selectedWordID,
            readingScale: layout.readingScale,
            onReview: currentTakes(prepared).isEmpty ? nil : { openReview(in: prepared) },
            runtime: sentenceRuntime(for: prepared),
            onWord: { showWord($0, in: prepared) })
        },
        review: {
          if let storedTake {
            let take = practiceTake(storedTake, in: prepared)
            ShadowingReviewScaffold(
              layout: layout, onBack: { showingReview = false },
              source: { productionVideo(lesson: lesson) },
              sentence: {
                SentenceView(
                  sentence: take.sourceSnapshot, selectedWordID: $selectedWordID, compact: true,
                  runtime: sentenceRuntime(for: prepared),
                  onWord: { showWord($0, in: prepared) })
              },
              panel: {
                ReviewPanelView(
                take: take,
                onRecordAgain: {
                  showingReview = false
                  model.listenThenRecord()
                },
                onPracticePhrase: { _ in },
                runtime: ReviewRuntimePresentation(
                  history: practiceTakes(in: prepared), selectedTakeID: take.id,
                  onSelectTake: { selectedTakeID = UUID(uuidString: $0) },
                  onPreviewOriginal: { model.preview(prepared.targetSpan, speed: storedTake.sourceSpeed) },
                  onPreviewTake: { model.replay(storedTake) },
                  onCompare: { model.compare(storedTake) },
                  assessmentUnavailableText:
                    "Bản thu thật đã lưu. Đánh giá phát âm sẽ được nối ở B4."))
                .id(take.id)
              })
          }
        },
        supplementary: { EmptyView() },
        transport: {
          PracticeTransportView(
            onOptions: {
              model.pause()
              showingRepeatOptions = true
            },
            onReview: { openReview(in: prepared) },
            compact: layout.contentWidth < 950, contentScale: layout.controlScale,
            productionModel: model)
            .popover(isPresented: $showingRepeatOptions, arrowEdge: .top) {
              RepeatOptionsView(onClose: { showingRepeatOptions = false })
            }
        })
      .sheet(item: $overlay) { item in
          switch item {
          case .word(let id):
            if let token = prepared.tokens.first(where: { $0.id == id }) {
              ProductionWordPronunciationSheet(
                sentence: sentence, token: token,
                onPreview: { model.preview(token, speed: wordPreviewSpeed) },
                onEditTiming: { present(.timing(id)) },
                onClose: { overlay = nil },
                runtime: WordPronunciationRuntime(
                  previewSpeed: $wordPreviewSpeed,
                  interactionDisabled: model.controller.phase.isCapture
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
      .sheet(isPresented: $showingMicrophone) {
          MicrophonePreviewSheet(runtime: MicrophoneRuntimeActions(
            permissionDenied: model.controller.permission == .denied
              || model.controller.permission == .restricted,
            onListenOnly: {
              store.preferences.autoRecord = false
              showingMicrophone = false
            },
            onRetry: {
              showingMicrophone = false
              model.retryRecordPermission()
            },
            onOpenSettings: {
              guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
              else { return }
              NSWorkspace.shared.open(url)
            }))
      }
      } else if model.isLoading {
        EchoLoading(title: "production.practice.preparing")
      } else {
        EchoEmptyState(
          title: "Choose a prepared lesson",
          message: "Import a lesson with an English transcript before practicing.",
          symbol: "headphones")
      }
    }
    .task {
      wordPreviewSpeed = store.preferences.speed
      model.applyPreferences(store.preferences)
      await model.load()
    }
    .task(id: model.lesson?.id) {
      videoFollower.configure(
        source: store.preferences.video ? model.lesson?.youtubeVisualSource : nil)
      translationConfiguration = model.lesson.map { _ in
        TranslationSession.Configuration(
          source: AppleTranslationPreparer.source, target: AppleTranslationPreparer.target)
      }
      synchronizeVideo()
    }
    .translationTask(translationConfiguration) { session in
      guard let lessonID = model.lesson?.id else { return }
      await model.prepareVietnameseTranslation(session: session, lessonID: lessonID)
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
      videoFollower.configure(source: enabled ? model.lesson?.youtubeVisualSource : nil)
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
      if let error = model.error
        ?? model.controller.error.map({
          EchoCopy("storage.detail", arguments: [.raw($0.localizedDescription)])
        })
      {
        EchoNotice(copy: error, error: true).padding(24)
      }
    }
  }

  private var presentationLesson: Lesson? {
    guard let source = model.lesson else { return nil }
    let sentences = model.preparedSentences.enumerated().map {
      $0.element.lessonSentence(number: $0.offset + 1)
    }
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
    let sentenceNumber = model.preparedSentences.firstIndex(where: { $0.id == sentence.id })
      .map { $0 + 1 } ?? 1
    return currentTakes(sentence).enumerated().map {
      sentence.practiceTake($0.element, number: $0.offset + 1, sentenceNumber: sentenceNumber)
    }
  }

  private func practiceTake(
    _ take: ProductionStoredTake, in sentence: ProductionPreparedSentence
  ) -> PracticeTake {
    let all = currentTakes(sentence)
    let number = all.firstIndex(where: { $0.id == take.id }).map { $0 + 1 } ?? all.count
    let sentenceNumber = model.preparedSentences.firstIndex(where: { $0.id == sentence.id })
      .map { $0 + 1 } ?? 1
    return sentence.practiceTake(take, number: number, sentenceNumber: sentenceNumber)
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

  private func sentenceRuntime(
    for sentence: ProductionPreparedSentence
  ) -> SentenceRuntimePresentation {
    let storedTake = currentTakes(sentence).last
    let take = storedTake.map { practiceTake($0, in: sentence) }
    return SentenceRuntimePresentation(
      playingWordID: playingWordID(in: sentence),
      interactionDisabled: model.controller.phase.isCapture
        || model.controller.phase == .saving || model.controller.phase == .saveFailed,
      hasCurrentTake: !currentTakes(sentence).isEmpty,
      takeCount: currentTakes(sentence).count,
      sentenceCount: model.preparedSentences.count,
      translationPlaceholder: model.isPreparingTranslation
        ? "Đang chuẩn bị bản dịch tiếng Việt…"
        : "Chưa có bản dịch · mở chỉnh timing để bổ sung.",
      currentTake: take,
      feedbackActions: storedTake.map { stored in
        InlineFeedbackRuntimeActions(
          actionsBlocked: model.controller.phase.isCapture
            || [.countdown, .saving, .saveFailed].contains(model.controller.phase),
          onCheckMicrophone: { showingMicrophone = true },
          onCompare: { model.compare(stored) },
          onRetry: { openReview(in: sentence) },
          onReview: {
            selectedTakeID = stored.id
            showingReview = true
          })
      })
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
    guard model.controller.phase == .listening else { return nil }
    let frame = Int((model.controller.sourcePosition * Double(sentence.target.sampleRate)).rounded())
    return sentence.tokens.first(where: { token in
      guard !token.needsTimingReview, let start = token.startFrame, let end = token.endFrame else {
        return false
      }
      return frame >= start && frame < end
    })?.id
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

  private func synchronizeVideo() {
    videoFollower.follow(
      sourceSeconds: model.controller.sourcePosition,
      isNativeAudioPlaying: store.preferences.video && model.controller.phase == .listening)
  }
}
