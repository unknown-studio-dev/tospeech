import Foundation
import Observation
@preconcurrency import Translation

/// Connects the native practice controls only to an immutable revision returned
/// by the production database. It deliberately carries no preview lesson data.
@MainActor @Observable
final class ProductionShadowingModel {
  private let service: ProductionPracticeService
  private let translationPreparer: AppleTranslationPreparer?
  private let ipaPreparer: IPAAnnotationPreparer?
  private let wordTimingPreparer: AppleSpeechWordTimingPreparer?
  let controller: ProductionPracticeController
  private var practiceOptions = Preferences()
  private var ipaBackfillAttempted: Set<UUID> = []
  var showingSpeechPreparation = false
  private(set) var isPreparingWordTiming = false
  private(set) var speechPreparationError: EchoCopy?
  private var wordTimingTask: Task<Void, Never>?
  private var wordTimingRequestID: UUID?

  private(set) var lesson: LibraryLessonSummary?
  private(set) var targets: [ProductionPracticeTarget] = []
  private(set) var preparedSentences: [ProductionPreparedSentence] = [] {
    didSet { cachedLessonSentences = nil }
  }
  /// Decoding IPA/translation JSON per word is expensive, so the mapped
  /// sentences are memoized here and rebuilt only when `preparedSentences`
  /// changes — never on every SwiftUI render. `@ObservationIgnored` keeps the
  /// cache write out of the observation graph (no re-render loop).
  @ObservationIgnored private var cachedLessonSentences: [LessonSentence]?
  var lessonSentences: [LessonSentence] {
    if let cachedLessonSentences { return cachedLessonSentences }
    let computed = preparedSentences.enumerated().map {
      $0.element.lessonSentence(number: $0.offset + 1)
    }
    cachedLessonSentences = computed
    return computed
  }
  private(set) var takes: [ProductionStoredTake] = []
  var selectedTarget: ProductionPracticeTarget?
  private(set) var isLoading = false
  private(set) var isPreparingTranslation = false
  private(set) var waveformSamples: [Double]?
  private(set) var isPreparingWaveform = false
  private(set) var waveformError: String?
  var error: EchoCopy?

  init(
    service: ProductionPracticeService, controller: ProductionPracticeController,
    translationPreparer: AppleTranslationPreparer? = nil,
    ipaPreparer: IPAAnnotationPreparer? = nil,
    wordTimingPreparer: AppleSpeechWordTimingPreparer? = nil
  ) {
    self.service = service
    self.controller = controller
    self.translationPreparer = translationPreparer
    self.ipaPreparer = ipaPreparer
    self.wordTimingPreparer = wordTimingPreparer
    controller.onSingleListenCompleted = { [weak self] revisionID, repeating in
      self?.advanceAfterSingleListen(revisionID: revisionID, repeating: repeating)
    }
  }

  func open(_ lesson: LibraryLessonSummary, preferences: Preferences) {
    self.lesson = lesson
    practiceOptions = preferences
    targets = []
    preparedSentences = []
    takes = []
    selectedTarget = nil
    error = nil
    waveformSamples = nil
    waveformError = nil
    dismissSpeechPreparation()
    Task { await load() }
  }

  func load() async {
    guard let lesson, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      var loaded = try await service.preparedSentences(lessonID: lesson.id)
      guard !loaded.isEmpty else {
        error = EchoCopy("production.practice.no_target")
        return
      }
      if let ipaPreparer, !ipaBackfillAttempted.contains(lesson.id), needsIPABackfill(loaded) {
        ipaBackfillAttempted.insert(lesson.id)
        do {
          try await ipaPreparer.prepare(lessonID: lesson.id)
          loaded = try await service.preparedSentences(lessonID: lesson.id)
        } catch {
          ipaBackfillAttempted.remove(lesson.id)
          self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
        }
      }
      preparedSentences = loaded
      targets = loaded.map(\.target)
      takes = try await service.takes(lessonID: lesson.id)
      let previousID = selectedTarget?.segmentID
      let next =
        loaded.first(where: { $0.target.segmentID == previousID })?.target ?? loaded[0].target
      // Translation annotation refreshes must not reset an active listen/capture
      // controller when its immutable practice target did not change.
      if selectedTarget?.segmentRevisionID != next.segmentRevisionID {
        select(next)
      } else {
        selectedTarget = next
      }
    } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  var canPrepareWordTiming: Bool {
    wordTimingPreparer != nil && needsWordTimingBackfill(preparedSentences)
      && !isLoading && !controller.phase.isCapture && controller.phase != .saving
      && controller.phase != .saveFailed
  }

  func presentSpeechPreparation() {
    guard canPrepareWordTiming else { return }
    pause()
    speechPreparationError = nil
    showingSpeechPreparation = true
  }

  func dismissSpeechPreparation() {
    wordTimingTask?.cancel()
    wordTimingTask = nil
    wordTimingRequestID = nil
    isPreparingWordTiming = false
    showingSpeechPreparation = false
    speechPreparationError = nil
  }

  /// Only the explicit Continue action may request Speech consent or run backfill.
  func startWordTimingPreparation() {
    guard showingSpeechPreparation, !isPreparingWordTiming,
      let wordTimingPreparer, let lessonID = lesson?.id else { return }
    let sentences = preparedSentences
    let localeIdentifier = practiceOptions.accent == .uk ? "en-GB" : "en-US"
    let requestID = UUID()
    wordTimingRequestID = requestID
    isPreparingWordTiming = true
    speechPreparationError = nil
    wordTimingTask = Task { [weak self] in
      do {
        let changed = try await wordTimingPreparer.prepare(sentences: sentences, localeIdentifier: localeIdentifier)
        try Task.checkCancellation()
        guard let self, self.lesson?.id == lessonID, self.wordTimingRequestID == requestID else { return }
        if changed { await self.load() }
        guard self.wordTimingRequestID == requestID else { return }
        self.isPreparingWordTiming = false
        self.wordTimingTask = nil
        if changed {
          self.showingSpeechPreparation = false
        } else {
          self.speechPreparationError = EchoCopy("speech.preparation.no_changes")
        }
      } catch {
        guard let self, self.wordTimingRequestID == requestID else { return }
        self.isPreparingWordTiming = false
        self.wordTimingTask = nil
        if error is CancellationError { return }
        if error is SpeechAnalyzerPreparationError {
          self.speechPreparationError = EchoCopy("speech.preparation.unavailable")
          return
        }
        switch error as? AppleSpeechCaptionError {
        case .permissionDenied: self.speechPreparationError = EchoCopy("speech.preparation.denied")
        case .onDeviceRecognitionUnavailable, .recognizerUnavailable:
          self.speechPreparationError = EchoCopy("speech.preparation.unavailable")
        case .timedOut: self.speechPreparationError = EchoCopy("speech.preparation.timeout")
        default:
          self.speechPreparationError = EchoCopy("speech.preparation.failed", arguments: [.raw(error.localizedDescription)])
        }
      }
    }
  }

  func select(_ target: ProductionPracticeTarget) {
    guard !controller.phase.isCapture, controller.phase != .saving,
      controller.phase != .saveFailed
    else {
      error = EchoCopy("Dừng hoặc lưu xong bản thu trước khi đổi câu.")
      return
    }
    if controller.phase == .listening { controller.pauseAndKeep() }
    do {
      let maximumDuration = max(4, min(30, target.duration * 2.5))
      try controller.configure(
        target: target, sourceSpeed: practiceOptions.speed,
        policy: ProductionCapturePolicy(
          countdown: practiceOptions.countdown, trailingSilence: practiceOptions.silence,
          maximumDuration: min(practiceOptions.maxDuration, maximumDuration)),
        repeatCount: practiceOptions.repeats, autoRecord: practiceOptions.autoRecord)
      selectedTarget = target
      error = nil
    } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func selectAndListen(revisionID: String) {
    guard let id = UUID(uuidString: revisionID),
      let target = targets.first(where: { $0.segmentRevisionID == id })
    else { return }
    select(target)
    guard selectedTarget?.segmentRevisionID == id else { return }
    listen()
  }

  func sentence(for target: ProductionPracticeTarget?) -> ProductionPreparedSentence? {
    guard let target else { return nil }
    return preparedSentences.first { $0.target.segmentRevisionID == target.segmentRevisionID }
  }

  func takes(for sentence: ProductionPreparedSentence) -> [ProductionStoredTake] {
    takes.filter {
      $0.segmentRevisionID == sentence.target.segmentRevisionID && $0.status == "ready"
    }
  }

  func refreshTakes() async {
    guard let lesson else { return }
    do { takes = try await service.takes(lessonID: lesson.id) } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func prepareWaveform() async {
    guard waveformSamples == nil, !isPreparingWaveform, let lesson, let target = selectedTarget,
      let duration = lesson.duration
    else { return }
    isPreparingWaveform = true
    waveformError = nil
    defer { isPreparingWaveform = false }
    do {
      waveformSamples = try await service.waveformSamples(
        audioURL: target.audioURL, sampleRate: target.sampleRate, duration: duration)
    } catch {
      waveformError = error.localizedDescription
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func retryWaveform() async {
    waveformSamples = nil
    waveformError = nil
    await prepareWaveform()
  }

  func preview(_ token: TranscriptWordToken, speed: Double = 1) {
    guard let target = selectedTarget, !controller.phase.isCapture, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.preview(token, in: target, speed: speed) } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func preview(_ span: AudioSpan, speed: Double = 1) {
    guard let target = selectedTarget, !controller.phase.isCapture, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.preview(span, in: target, speed: speed) } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func publishTimingDraft(
    _ draft: LessonSentence, from source: ProductionPreparedSentence
  ) async -> String? {
    guard draft.text == source.target.text else {
      return "Transcript editing is not available in this timing-only revision."
    }
    let wordsByID = Dictionary(uniqueKeysWithValues: draft.words.map { ($0.id, $0) })
    let tokens = source.tokens.map { token in
      let word = wordsByID[token.id]
      return TranscriptWordToken(
        id: token.id, text: token.text,
        startFrame: word?.span.map {
          Int(($0.start * Double(source.target.sampleRate)).rounded())
        },
        endFrame: word?.span.map {
          Int(($0.end * Double(source.target.sampleRate)).rounded())
        },
        needsTimingReview: word?.span == nil)
    }
    let revisionDraft = SegmentTimingRevisionDraft(
      segmentID: source.target.segmentID,
      expectedRevisionID: source.target.segmentRevisionID,
      startFrame: Int((draft.span.start * Double(source.target.sampleRate)).rounded()),
      endFrame: Int((draft.span.end * Double(source.target.sampleRate)).rounded()),
      tokens: tokens,
      resolvesTimingReview: tokens.allSatisfy { $0.startFrame != nil && $0.endFrame != nil })
    do {
      let revision = try await service.publishTimingRevision(revisionDraft)
      if draft.translation != (source.vietnameseTranslation ?? "") {
        try await service.storeVietnameseOverride(
          revisionID: revision.revisionID, text: draft.translation)
      }
      await load()
      return nil
    } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
      return "timing.save.failed"
    }
  }

  func replay(_ take: ProductionStoredTake) {
    guard !controller.phase.isCapture, controller.phase != .saving else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.playTake(take) } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func compare(_ take: ProductionStoredTake) {
    guard let target = selectedTarget, target.segmentRevisionID == take.segmentRevisionID,
      !controller.phase.isCapture, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.compare(target, with: take) } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  func publishTimingRevision(_ draft: SegmentTimingRevisionDraft) async -> Bool {
    do {
      let revision = try await service.publishTimingRevision(draft)
      await load()
      if let replacement = targets.first(where: { $0.segmentRevisionID == revision.revisionID }) {
        select(replacement)
      }
      return true
    } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
      return false
    }
  }

  func applyPreferences(_ preferences: Preferences) {
    practiceOptions = preferences
    guard let target = selectedTarget,
      let policy = try? ProductionCapturePolicy(
        countdown: preferences.countdown, trailingSilence: preferences.silence,
        maximumDuration: min(preferences.maxDuration, max(4, min(30, target.duration * 2.5))))
    else { return }
    controller.updateOptions(
      sourceSpeed: preferences.speed, policy: policy,
      repeatCount: preferences.repeats, autoRecord: preferences.autoRecord)
  }

  func listen() { controller.listen() }
  func listenLoop() { controller.listen(repeating: true) }
  func listenThenRecord() { controller.listen(thenCapture: true) }
  func resumeSource() { controller.resumeFromSource() }
  func record() { controller.requestRecord() }
  func retryRecordPermission() { controller.retryRecordPermission() }
  func cancelCountdown() { controller.cancelCountdown() }
  func finishRecording() { controller.finishRecording() }
  func setSourceSpeed(_ value: Double) { controller.setSourceSpeed(value) }
  func pause() { controller.pauseAndKeep() }
  func retrySave() { controller.retrySave() }
  func discardPending() { controller.discardPending() }

  func prepareForNavigation() -> Bool {
    switch controller.phase {
    case .awaitingSpeech, .recording, .trailingSilence, .saving, .saveFailed:
      error = EchoCopy("Dừng và lưu hoặc bỏ bản thu hiện tại trước khi rời màn luyện.")
      return false
    case .listening, .countdown:
      controller.pauseAndKeep()
      return true
    default:
      return true
    }
  }

  func selectRelative(_ delta: Int) {
    guard let selectedTarget,
      let index = targets.firstIndex(where: {
        $0.segmentRevisionID == selectedTarget.segmentRevisionID
      }),
      targets.indices.contains(index + delta)
    else { return }
    select(targets[index + delta])
  }

  private func advanceAfterSingleListen(revisionID: UUID, repeating: Bool) {
    guard practiceOptions.repeats == 1, selectedTarget?.segmentRevisionID == revisionID,
      let index = targets.firstIndex(where: { $0.segmentRevisionID == revisionID }),
      targets.indices.contains(index + 1)
    else { return }
    let next = targets[index + 1]
    select(next)
    guard selectedTarget?.segmentRevisionID == next.segmentRevisionID, controller.phase == .idle else {
      return
    }
    controller.listen(repeating: repeating)
  }

  func canSelectRelative(_ delta: Int) -> Bool {
    guard let selectedTarget,
      let index = targets.firstIndex(where: {
        $0.segmentRevisionID == selectedTarget.segmentRevisionID
      })
    else { return false }
    return targets.indices.contains(index + delta)
  }

  /// The view supplies its system-managed session through `translationTask`.
  /// This keeps language-pack consent in SwiftUI and does not introduce a
  /// network translation fallback.
  func prepareVietnameseTranslation(session: TranslationSession, lessonID: UUID) async {
    guard lesson?.id == lessonID, let translationPreparer, !isPreparingTranslation else { return }
    isPreparingTranslation = true
    defer { isPreparingTranslation = false }
    do {
      try await translationPreparer.prepare(using: session)
      try await translationPreparer.translate(lessonID: lessonID, using: session)
      await load()
    } catch {
      self.error = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  /// A token needs IPA backfill only when it has *no* pronunciation for either
  /// accent — meaning it was never looked up. A token with one accent present
  /// but the other missing is a genuine dictionary gap (e.g. a proper noun
  /// absent from the British RP dictionary); backfilling cannot fill it, so
  /// requiring both accents here would re-run the whole pass on every open.
  private func needsIPABackfill(_ sentences: [ProductionPreparedSentence]) -> Bool {
    sentences.contains { sentence in
      sentence.tokens.contains { token in
        sentence.ipa(for: token, accent: .uk) == nil
          && sentence.ipa(for: token, accent: .us) == nil
      }
    }
  }

  private func needsWordTimingBackfill(_ sentences: [ProductionPreparedSentence]) -> Bool {
    sentences.contains { sentence in
      sentence.tokens.contains { token in
        IPAFormatting.isPronounceable(token.text)
          && (token.startFrame == nil || token.endFrame == nil || token.needsTimingReview)
      }
    }
  }
}
