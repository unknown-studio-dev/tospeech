import Foundation
import Observation


/// Drives deterministic UI simulations. Production playback must use the native audio clock.
@MainActor @Observable
final class PracticeController {
  var phase: PracticePhase = .idle
  var round = 1
  var remaining = 0.0
  var elapsed = 0.0
  var sourcePosition = 0.0
  var previewSpeed = 0.75
  var lastPreview: EchoCopy?
  var permission: String = "unknown"
  var permissionPresented = false
  var simulatedOutcome: CaptureOutcome = .complete
  var simulateSaveFailure = false
  var scope: PracticeScope = .sentence
  var phraseWordIDs: [String] = []
  var hasListened = false
  var pendingTake: PracticeTake?
  @ObservationIgnored unowned let store: EchoStore
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  private var target: LessonSentence?
  private var lessonID: String?
  private var roundPreferences = Preferences()
  private var span = AudioSpan(start: 0, end: 1)
  private var repeatEnabled = false
  private var captureAfterSource = false
  private var captureClock = 0.0
  private var speechClock = 0.0
  private var hasSentenceClock = false
  var isRepeating: Bool { repeatEnabled }

  init(store: EchoStore) { self.store = store }

  func playSentence(repeating: Bool? = nil) {
    guard interrupt(), prepareSelectedTarget() else { return }
    round = 1
    repeatEnabled = repeating ?? (roundPreferences.repeats > 1)
    sourcePosition = span.start
    remaining = span.duration / roundPreferences.speed
    elapsed = 0
    hasListened = false
    phase = .listening
    lastPreview = EchoCopy(
      "preview.source_range",
      arguments: [.raw(EchoFormat.time(span.start)), .raw(EchoFormat.time(span.end))])
    startTicker()
  }

  func previewSource(span: AudioSpan, label: String) {
    guard interrupt() else { return }
    hasSentenceClock = false
    lastPreview = EchoCopy(
      "preview.labeled_range",
      arguments: [
        .localized(label), .raw(EchoFormat.decimal(span.start)),
        .raw(EchoFormat.decimal(span.end)), .raw(EchoFormat.decimal(previewSpeed)),
      ])
    sourcePosition = span.start
  }
  var sourceSeekRange: AudioSpan? {
    guard let sentence = store.selectedSentence else { return nil }
    let words = sentence.words.filter { phraseWordIDs.contains($0.id) }.compactMap(\.span)
    if scope == .phrase, let start = words.map(\.start).min(), let end = words.map(\.end).max() {
      return AudioSpan(start: start, end: end)
    }
    return sentence.span
  }

  /// Preview-only seek. Scrubbing never starts capture or counts as finishing a listen.
  func seekSource(to position: Double) {
    guard position.isFinite, [.idle, .paused, .listening].contains(phase),
      let range = sourceSeekRange
    else { return }
    sourcePosition = min(range.end, max(range.start, position))
    if phase == .listening { remaining = (range.end - sourcePosition) / roundPreferences.speed }
    lastPreview = EchoCopy(
      "preview.source_seek", arguments: [.raw(EchoFormat.decimal(sourcePosition))])
  }
  func previewWord(sentence: LessonSentence, wordID: String) {
    guard let word = sentence.words.first(where: { $0.id == wordID }) else { return }
    previewSource(
      span: word.span ?? sentence.span,
      label: word.span == nil ? "Hear in context" : "Original word")
  }
  func previewReference(word: LessonWord, accent: ReferenceAccent) {
    guard interrupt() else { return }
    hasSentenceClock = false
    lastPreview = EchoCopy(
      "preview.dictionary_reference",
      arguments: [.raw(accent.rawValue), .raw(word.text)])
  }
  func beginPhrase(_ wordIDs: [String]) {
    guard interrupt() else { return }
    phraseWordIDs = wordIDs
    scope = .phrase
    playSentence()
  }
  func clearScope() {
    scope = .sentence
    phraseWordIDs = []
    hasListened = false
  }
  func resetTarget() {
    clearScope()
    target = nil
    hasSentenceClock = false
    lessonID = nil
    hasListened = false
    lastPreview = nil
    phase = .idle
  }
  func requestRecord() {
    guard phase != .saving && phase != .saveFailed && !phase.isCapture else { return }
    guard interrupt(), prepareSelectedTarget() else { return }
    if permission != "granted" {
      permissionPresented = true
      return
    }
    beginCountdown()
  }
  func allowPermission() {
    permission = "granted"
    permissionPresented = false
    requestRecord()
  }
  func denyPermission() {
    permission = "denied"
    permissionPresented = false
    store.message = EchoCopy("Microphone denied in this simulation. Listening remains available.")
  }
  func listenOnly() {
    permissionPresented = false
    store.preferences.autoRecord = false
  }
  func sourceFinished() {
    guard phase == .listening else { return }
    sourcePosition = span.end
    hasListened = true
    if captureAfterSource || roundPreferences.autoRecord {
      captureAfterSource = false
      if permission == "granted" {
        beginCountdown()
      } else {
        phase = .paused
        ticker?.cancel()
        permissionPresented = true
      }
    } else if repeatEnabled && round < roundPreferences.repeats {
      round += 1
      sourcePosition = span.start
      remaining = span.duration / roundPreferences.speed
    } else {
      phase = .paused
      ticker?.cancel()
      if (roundPreferences.repeats == 1 || repeatEnabled), scope == .sentence,
        let lesson = store.selectedLesson,
        let index = lesson.sentences.firstIndex(where: { $0.id == target?.id }),
        lesson.sentences.indices.contains(index + 1)
      {
        let repeating = repeatEnabled
        store.selectSentence(lesson.sentences[index + 1].id)
        playSentence(repeating: repeating)
      }
    }
  }
  private func beginCountdown() {
    guard target != nil else { return }
    phase = .countdown
    remaining = roundPreferences.countdown
    startTicker()
  }

  private func prepareSelectedTarget() -> Bool {
    guard let sentence = store.selectedSentence else { return false }
    target = sentence
    hasSentenceClock = true
    lessonID = store.selectedLessonID
    roundPreferences = store.preferences
    let selected = sentence.words.filter { phraseWordIDs.contains($0.id) }.compactMap(\.span)
    span =
      scope == .phrase && !selected.isEmpty
      ? AudioSpan(start: selected.map(\.start).min()!, end: selected.map(\.end).max()!)
      : sentence.span
    sourcePosition = span.start
    return true
  }
  func cancelCountdown() {
    guard phase == .countdown else { return }
    ticker?.cancel()
    ticker = nil
    captureAfterSource = false
    repeatEnabled = false
    remaining = 0
    phase = .paused
  }
  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self else { return }
        self.advance(by: 0.1)
      }
    }
  }
  // Exposed internally for deterministic lifecycle tests without wall-clock sleeps.
  func advance(by delta: Double) {
    guard delta.isFinite && delta > 0 else { return }
    switch phase {
    case .listening:
      remaining -= delta
      sourcePosition = min(span.end, sourcePosition + delta * roundPreferences.speed)
      if remaining <= 0 { sourceFinished() }
    case .countdown:
      remaining -= delta
      if remaining <= 0 {
        phase = .awaitingSpeech
        elapsed = 0
        captureClock = 0
        speechClock = 0
      }
    case .awaitingSpeech, .recording, .trailingSilence:
      elapsed += delta
      captureClock += delta
      if captureClock >= roundPreferences.maxDuration {
        finishRecording()
        return
      }
      if phase == .awaitingSpeech && elapsed >= 0.6 && simulatedOutcome != .noSpeech {
        speechDetected()
      } else if phase == .recording {
        speechClock += delta
        if speechClock >= 2.4 {
          phase = .trailingSilence
          remaining = roundPreferences.silence
        }
      } else if phase == .trailingSilence {
        remaining -= delta
        if remaining <= 0 { finishRecording() }
      }
    default: break
    }
  }
  func speechDetected() {
    guard phase.isCapture else { return }
    phase = .recording
    speechClock = 0
    remaining = roundPreferences.silence
  }
  func finishRecording() {
    guard phase.isCapture else { return }
    let outcome: CaptureOutcome = phase == .awaitingSpeech ? .noSpeech : simulatedOutcome
    prepareTake(outcome: outcome)
    savePending()
  }
  private func prepareTake(outcome: CaptureOutcome) {
    guard let target, let lessonID else { return }
    let count = store.takes.filter { $0.lessonID == lessonID && $0.sentenceID == target.id }.count
    pendingTake = PracticeTake(
      id: UUID().uuidString, lessonID: lessonID, sentenceID: target.id, number: count + 1,
      createdAt: Date(), duration: elapsed, outcome: outcome, sourceSnapshot: target,
      sourceSpeed: roundPreferences.speed, scope: scope,
      wordIDs: scope == .sentence ? target.words.map(\.id) : phraseWordIDs, assessments: [])
    ticker?.cancel()
  }
  private func savePending() {
    guard pendingTake != nil else { return }
    phase = .saving
    saveTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      self?.commitPending()
    }
  }
  func commitPending() {
    guard let take = pendingTake else { return }
    saveTask?.cancel()
    saveTask = nil
    if simulateSaveFailure {
      phase = .saveFailed
      return
    }
    guard store.commitPreviewTake(take) else {
      phase = .saveFailed
      return
    }
    pendingTake = nil
    if [.complete, .earlyStop].contains(take.outcome) { store.requestAssessment(takeID: take.id) }
    if take.outcome != .interrupted && repeatEnabled && round < roundPreferences.repeats {
      round += 1
      phase = .listening
      elapsed = 0
      sourcePosition = span.start
      remaining = span.duration / roundPreferences.speed
      startTicker()
    } else {
      phase = .feedback
    }
  }
  func retrySave() {
    simulateSaveFailure = false
    savePending()
  }

  /// Only known, unambiguous intervals in the current source revision receive karaoke.
  /// The clock here is simulated; production must feed this from native audio playback.
  func playingWordID(in sentence: LessonSentence) -> String? {
    guard hasSentenceClock, [.listening, .paused].contains(phase),
      lessonID == store.selectedLessonID, target?.id == sentence.id,
      target?.revision == sentence.revision, sourcePosition.isFinite
    else { return nil }
    let started = sentence.words.compactMap { word -> (LessonWord, Double)? in
      guard !word.needsTimingReview, let interval = word.span,
        interval.isValid(duration: sentence.span.end), interval.start >= sentence.span.start
        && IPAFormatting.isPronounceable(word.text), interval.start <= sourcePosition
      else { return nil }
      return (word, interval.start)
    }
    guard let latestStart = started.map({ $0.1 }).max() else { return nil }
    let matches = started.filter { $0.1 == latestStart }
    return matches.count == 1 ? matches[0].0.id : nil
  }
  func discardPending() {
    ticker?.cancel()
    ticker = nil
    saveTask?.cancel()
    saveTask = nil
    pendingTake = nil
    phase = .paused
    repeatEnabled = false
  }
  @discardableResult func interrupt() -> Bool {
    if phase == .saveFailed || phase == .saving {
      store.message = EchoCopy("Save or explicitly discard the retained take before leaving.")
      return false
    }
    ticker?.cancel()
    ticker = nil
    captureAfterSource = false
    if phase.isCapture {
      prepareTake(outcome: .interrupted)
      if simulateSaveFailure {
        phase = .saveFailed
        return false
      }
      guard let take = pendingTake, store.commitPreviewTake(take) else {
        phase = .saveFailed
        return false
      }
      pendingTake = nil
    }
    if phase != .idle { phase = .paused }
    repeatEnabled = false
    return true
  }

  deinit {
    ticker?.cancel()
    saveTask?.cancel()
  }
}
