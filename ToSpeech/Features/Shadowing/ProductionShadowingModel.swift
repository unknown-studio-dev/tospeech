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
  private let wordTimingPreparer: (any WordTimingPreparing)?
  let dictation: DictationModel
  let controller: ProductionPracticeController
  let matchingService: ContentMatchingService?
  let assessmentService: PronunciationAssessmentService?
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
  private(set) var savedTakeSentences: [UUID: ProductionPreparedSentence] = [:]
  var selectedTarget: ProductionPracticeTarget?
  private(set) var isLoading = false
  private(set) var isPreparingTranslation = false
  private(set) var waveformSamples: [Double]?
  private(set) var isPreparingWaveform = false
  private(set) var waveformError: String?
  var error: EchoCopy?

  init(
    service: ProductionPracticeService, controller: ProductionPracticeController, dictation: DictationModel,
    translationPreparer: AppleTranslationPreparer? = nil,
    ipaPreparer: IPAAnnotationPreparer? = nil,
    wordTimingPreparer: (any WordTimingPreparing)? = nil,
    matchingService: ContentMatchingService? = nil,
    assessmentService: PronunciationAssessmentService? = nil
  ) {
    self.dictation = dictation
    self.service = service
    self.controller = controller
    self.translationPreparer = translationPreparer
    self.ipaPreparer = ipaPreparer
    self.wordTimingPreparer = wordTimingPreparer
    self.matchingService = matchingService
    self.assessmentService = assessmentService
    service.player.onFailure = { [weak self] message in
      self?.controller.playbackFailed(message)
      self?.error = EchoCopy(message)
    }
    controller.onTakeSaved = { [weak self] take in
      guard let self else { return }
      let preferences = self.practiceOptions
      Task {
        await self.assessmentService?.enqueue(take, preferences: preferences)
        await self.matchingService?.enqueue(take, preferences: preferences)
      }
    }
    matchingService?.practiceIsBusy = { [weak controller, weak assessmentService] in
      guard let controller else { return false }
      return assessmentService?.isProcessing == true || controller.phase == .listening || controller.phase == .countdown
        || controller.phase.isCapture || controller.phase == .saving
    }
    assessmentService?.practiceIsBusy = { [weak controller, weak matchingService] in
      guard let controller else { return false }
      return matchingService?.jobs.contains(where: { $0.status == .running }) == true
        || controller.phase == .listening || controller.phase == .countdown
        || controller.phase.isCapture || controller.phase == .saving
    }
    controller.onListenSequenceCompleted = { [weak self] revisionID, repeating in
      self?.advanceAfterListenSequence(revisionID: revisionID, repeating: repeating)
    }
  }

  func open(_ lesson: LibraryLessonSummary, preferences: Preferences) {
    self.lesson = lesson
    practiceOptions = preferences
    service.enhanceRecordings = preferences.enhanceRecordings
    targets = []
    preparedSentences = []
    takes = []
    savedTakeSentences = [:]
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
        // The lesson was deleted (or has no usable sentences): drop any stale content so the
        // view shows the empty state instead of the previous lesson's transcript and sentence.
        preparedSentences = []
        targets = []
        takes = []
        savedTakeSentences = [:]
        selectedTarget = nil
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
          self.error = EchoCopy.describing(error)
        }
      }
      preparedSentences = loaded
      targets = loaded.map(\.target)
      takes = try await service.takes(lessonID: lesson.id)
      savedTakeSentences = try await service.savedTakeSentences(lessonID: lesson.id)
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
      self.error = EchoCopy.describing(error)
    }
  }

  var canPrepareWordTiming: Bool {
    wordTimingPreparer != nil && preparedSentences.contains { !$0.hasManualTiming }
      && !isLoading && controller.phase != .countdown && !controller.phase.isCapture && controller.phase != .saving
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

  /// Alignment runs only after the explicit Continue action, never on lesson open.
  func startWordTimingPreparation() {
    guard showingSpeechPreparation, canPrepareWordTiming, !isPreparingWordTiming,
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
        if let alignmentError = error as? WordAlignmentError {
          self.speechPreparationError = EchoCopy(alignmentError.localizationKey)
          return
        }
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
      // Recording window is fixed to the source sentence length so every take matches the
      // original timing; the user speaks for exactly that long, no silence-based early stop.
      try controller.configure(
        target: target, sourceSpeed: practiceOptions.speed,
        policy: ProductionCapturePolicy(
          countdown: practiceOptions.countdown, trailingSilence: practiceOptions.silence,
          maximumDuration: max(0.5, target.duration), fixedWindow: true),
        repeatCount: practiceOptions.repeats, autoRecord: practiceOptions.autoRecord)
      selectedTarget = target
      error = nil
    } catch {
      self.error = EchoCopy.describing(error)
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
      $0.status == "ready" && ($0.segmentRevisionID == sentence.target.segmentRevisionID
        || savedTakeSentences[$0.id]?.target.segmentID == sentence.target.segmentID)
    }
  }

  var canManageRecordings: Bool {
    lesson != nil && !takes.isEmpty && !controller.phase.isCapture
      && ![.countdown, .saving, .saveFailed].contains(controller.phase)
  }

  func allPracticeTakes() -> [PracticeTake] {
    takes.filter { $0.status == "ready" }.enumerated().compactMap { index, take in
      guard let saved = savedTakeSentences[take.id] else { return nil }
      let sentenceNumber = preparedSentences.firstIndex {
        $0.target.segmentID == saved.target.segmentID
      }.map { $0 + 1 } ?? 1
      return saved.practiceTake(take, number: index + 1, sentenceNumber: sentenceNumber)
    }
  }

  func recordingByteCounts() async -> [UUID: Int64] {
    await service.recordingByteCounts(takes.filter { $0.status == "ready" })
  }

  @discardableResult
  func deleteRecordings(_ ids: Set<UUID>) async throws -> Int64 {
    guard let lesson, canManageRecordings else {
      throw ProductionPracticeError.recoveryRequired(
        "Finish the current recording before managing saved recordings.")
    }
    _ = prepareForReferencePlayback()
    let bytes = try await service.deleteRecordings(ids: ids, lessonID: lesson.id)
    await refreshTakes()
    await matchingService?.recover()
    await assessmentService?.recover()
    return bytes
  }

  func refreshTakes() async {
    guard let lesson else { return }
    do {
      let takes = try await service.takes(lessonID: lesson.id)
      let saved = try await service.savedTakeSentences(lessonID: lesson.id)
      guard self.lesson?.id == lesson.id else { return }
      self.takes = takes
      self.savedTakeSentences = saved
    } catch {
      self.error = EchoCopy.describing(error)
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
      self.error = EchoCopy.describing(error)
    }
  }

  func retryWaveform() async {
    waveformSamples = nil
    waveformError = nil
    await prepareWaveform()
  }

  func previewLink(_ suggestion: LinkingSuggestion, revisionID: UUID, speed: Double) {
    guard !controller.phase.isCapture, controller.phase != .countdown,
      controller.phase != .saving, controller.phase != .saveFailed,
      let target = selectedTarget, target.segmentRevisionID == revisionID,
      let prepared = sentence(for: target),
      let index = preparedSentences.firstIndex(where: { $0.id == prepared.id }) else { return }
    let sentence = prepared.lessonSentence(number: index + 1)
    // Re-resolve against the current immutable revision instead of trusting a stale popover.
    guard let current = LinkingSuggestions.suggestions(in: sentence, accent: practiceOptions.accent)
      .first(where: { $0.id == suggestion.id }), let span = current.playbackSpan(in: sentence) else {
      error = EchoCopy("linking.play_unavailable")
      return
    }
    preview(span, speed: speed)
  }

  func prepareForReferencePlayback() -> Bool {
    guard !controller.phase.isCapture, controller.phase != .countdown,
      controller.phase != .saving, controller.phase != .saveFailed else { return false }
    controller.prepareForAuxiliaryPlayback()
    service.stopPlayback()
    return true
  }

  func stopAuxiliaryPlayback() { service.stopPlayback() }
  var reviewPlayer: ProductionAudioPlayer { service.player }

  func preview(_ token: TranscriptWordToken, speed: Double = 1) {
    guard let target = selectedTarget, !controller.phase.isCapture, controller.phase != .countdown,
      controller.phase != .saveFailed, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.preview(token, in: target, speed: speed) } catch {
      self.error = EchoCopy.describing(error)
    }
  }

  func preview(_ span: AudioSpan, speed: Double = 1) {
    guard let target = selectedTarget, !controller.phase.isCapture, controller.phase != .countdown,
      controller.phase != .saveFailed, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.preview(span, in: target, speed: speed) } catch {
      self.error = EchoCopy.describing(error)
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
      if draft.translation != (source.translation ?? "") {
        try await service.storeTranslationOverride(
          revisionID: revision.revisionID, text: draft.translation)
      }
      await load()
      return nil
    } catch {
      self.error = EchoCopy.describing(error)
      return "timing.save.failed"
    }
  }

  func assess(_ take: ProductionStoredTake, preferences: Preferences) {
    Task { await assessmentService?.enqueue(take, preferences: preferences, force: true) }
  }

  /// Opening an existing take with evaluation enabled fills only a missing result.
  /// The queue deduplicates repeated view appearances and retains terminal history.
  func assessIfNeeded(_ take: ProductionStoredTake, preferences: Preferences) async {
    await assessmentService?.enqueue(take, preferences: preferences)
    if let latest = assessmentService?.history(takeID: take.id).last,
      latest.status == .complete, latest.result != nil,
      latest.result?.delivery == nil || latest.result?.audioDecodingPolicy != "av-foundation-full-clip-v2" {
      // The user requested the complete review: append the new analysis once for
      // an opened historical take. Never overwrite its existing result.
      await assessmentService?.enqueue(take, preferences: preferences, force: true)
    }
  }

  func compareDetail(_ take: ProductionStoredTake, source: AudioSpan, recorded: AudioSpan) {
    guard let target = savedTakeSentences[take.id]?.target, prepareForReferencePlayback() else { return }
    do {
      try service.compareDetail(target, take: take, sourceSpan: source, takeSpan: recorded) { [weak self] detail in
        self?.error = EchoCopy("storage.detail", arguments: [.raw(detail)])
      }
    } catch { self.error = EchoCopy.describing(error) }
  }

  func previewOriginalDetail(_ take: ProductionStoredTake, start: Double, end: Double) {
    guard let target = savedTakeSentences[take.id]?.target, prepareForReferencePlayback() else { return }
    do {
      let span = AudioSpan(start: start, end: end)
      _ = try PlaybackFrameRange.resolve(span, sampleRate: target.sampleRate,
        bounds: target.startFrame..<target.playbackEndFrame)
      try service.preview(span, in: target, speed: 1)
    }
    catch { self.error = EchoCopy.describing(error) }
  }

  func replayDetail(_ take: ProductionStoredTake, start: Double, end: Double) {
    guard prepareForReferencePlayback() else { return }
    do { try service.playTake(take, span: AudioSpan(start: start, end: end)) }
    catch { self.error = EchoCopy.describing(error) }
  }

  func match(_ take: ProductionStoredTake) {
    let preferences = practiceOptions
    Task { await matchingService?.rerun(take, preferences: preferences) }
  }

  func replay(_ take: ProductionStoredTake) {
    guard !controller.phase.isCapture, controller.phase != .saving else { return }
    controller.prepareForAuxiliaryPlayback()
    do { try service.playTake(take) } catch {
      self.error = EchoCopy.describing(error)
    }
  }

  func previewOriginal(_ take: ProductionStoredTake) {
    guard let target = savedTakeSentences[take.id]?.target ?? selectedTarget,
      target.segmentRevisionID == take.segmentRevisionID, prepareForReferencePlayback() else { return }
    do {
      try service.preview(AudioSpan(start: Double(target.startFrame) / Double(target.sampleRate),
        end: Double(target.playbackEndFrame) / Double(target.sampleRate)), in: target, speed: take.sourceSpeed)
    } catch { self.error = EchoCopy.describing(error) }
  }

  func reviewSourceURL(_ take: ProductionStoredTake) -> URL? {
    guard let target = savedTakeSentences[take.id]?.target ?? selectedTarget,
      target.segmentRevisionID == take.segmentRevisionID else { return nil }
    return target.audioURL
  }

  func reviewSourceAsset(_ take: ProductionStoredTake) -> ReviewAudioAsset? {
    guard let target = savedTakeSentences[take.id]?.target ?? selectedTarget,
      target.segmentRevisionID == take.segmentRevisionID else { return nil }
    return .init(id: "source", url: target.audioURL, sampleRate: target.sampleRate,
      startFrame: target.startFrame, endFrame: target.playbackEndFrame)
  }

  func reviewTakeAsset(_ take: ProductionStoredTake) -> ReviewAudioAsset? { service.reviewAudioAsset(take) }

  func compareTogether(_ take: ProductionStoredTake) {
    guard let target = savedTakeSentences[take.id]?.target ?? selectedTarget,
      target.segmentRevisionID == take.segmentRevisionID, prepareForReferencePlayback() else { return }
    do { try service.compareTogether(target, with: take) }
    catch { self.error = EchoCopy.describing(error) }
  }

  func compare(_ take: ProductionStoredTake) {
    guard let target = savedTakeSentences[take.id]?.target ?? selectedTarget, target.segmentRevisionID == take.segmentRevisionID,
      !controller.phase.isCapture, controller.phase != .countdown,
      controller.phase != .saveFailed, controller.phase != .saving
    else { return }
    controller.prepareForAuxiliaryPlayback()
    do {
      try service.compare(target, with: take) { [weak self] detail in
        self?.error = EchoCopy("storage.detail", arguments: [.raw(detail)])
      }
    } catch {
      self.error = EchoCopy.describing(error)
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
      self.error = EchoCopy.describing(error)
      return false
    }
  }

  func applyPreferences(_ preferences: Preferences) {
    practiceOptions = preferences
    service.enhanceRecordings = preferences.enhanceRecordings
    dictation.applyPreferredLimit(preferences.dictationTimeLimit)
    let language = TranslationLanguage(identifier: preferences.translationLanguage)
    if service.translationLanguage != language {
      // Re-stamp what is already loaded so the visible translation follows the
      // new native language at once; the translation task fills any gaps.
      service.translationLanguage = language
      preparedSentences = preparedSentences.map(service.stampingTranslationLanguage)
      savedTakeSentences = savedTakeSentences.mapValues(service.stampingTranslationLanguage)
    }
    guard let target = selectedTarget,
      let policy = try? ProductionCapturePolicy(
        countdown: preferences.countdown, trailingSilence: preferences.silence,
        maximumDuration: max(0.5, target.duration), fixedWindow: true)
    else { return }
    controller.updateOptions(
      sourceSpeed: preferences.speed, policy: policy,
      repeatCount: preferences.repeats, autoRecord: preferences.autoRecord)
  }

  func listen() {
    if controller.canResumeSource { controller.resumeFromSource() }
    else { controller.listen(repeating: practiceOptions.repeats > 1) }
  }
  func listenLoop() { controller.listen(repeating: true) }
  func listenThenRecord() { controller.listen(thenCapture: true) }
  func resumeSource() { controller.resumeFromSource() }
  func record() { controller.requestRecord() }
  func retryRecordPermission() { controller.retryRecordPermission() }
  func checkMicrophonePermission() { controller.checkMicrophonePermission() }
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

  private func advanceAfterListenSequence(revisionID: UUID, repeating: Bool) {
    guard selectedTarget?.segmentRevisionID == revisionID,
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
  func prepareTranslation(
    session: TranslationSession, lessonID: UUID, language: TranslationLanguage
  ) async {
    guard lesson?.id == lessonID, let translationPreparer, !isPreparingTranslation else { return }
    isPreparingTranslation = true
    defer { isPreparingTranslation = false }
    do {
      try await translationPreparer.prepare(using: session)
      try await translationPreparer.translate(lessonID: lessonID, into: language, using: session)
      await load()
    } catch {
      self.error = EchoCopy.describing(error)
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

}
