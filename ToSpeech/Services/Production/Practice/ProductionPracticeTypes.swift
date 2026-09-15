import Foundation

struct ProductionPracticeTarget: Codable, Equatable, Sendable {
  let lessonID: UUID
  let lessonGeneration: Int
  let segmentID: UUID
  let segmentRevisionID: UUID
  let audioAssetID: UUID
  let audioURL: URL
  let sampleRate: Int
  let startFrame: Int
  let endFrame: Int
  let text: String
  let scope: PracticeScope
  let wordIDs: [String]
  /// Listening context only; immutable sentence and word timing remain unchanged.
  var sourcePlaybackEndFrame: Int? = nil

  var playbackEndFrame: Int { sourcePlaybackEndFrame ?? endFrame }
  var frameCount: Int { endFrame - startFrame }
  var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
  var snapshot: ProductionPracticeTargetSnapshot {
    ProductionPracticeTargetSnapshot(
      lessonID: lessonID, lessonGeneration: lessonGeneration, segmentID: segmentID,
      segmentRevisionID: segmentRevisionID, audioAssetID: audioAssetID,
      sampleRate: sampleRate, startFrame: startFrame, endFrame: endFrame,
      text: text, scope: scope, wordIDs: wordIDs,
      sourcePlaybackEndFrame: sourcePlaybackEndFrame)
  }

  func validate() throws {
    guard lessonGeneration >= 1, sampleRate > 0, startFrame >= 0,
      endFrame > startFrame, playbackEndFrame >= endFrame, !text.isEmpty
    else { throw ProductionPracticeError.invalidTarget }
  }
}

enum SentencePlaybackBoundary {
  /// ASR word ends can clip a final consonant. Keep at most 250 ms of source
  /// context, without extending into the next sentence or past EOF. This is a
  /// playback margin, not an assertion that ASR timestamps are verified silence.
  static func endFrame(
    sentenceEnd: Int, sampleRate: Int, audioFrameCount: Int,
    nextSentenceStart: Int?, hasTimingOverride: Bool
  ) -> Int {
    guard !hasTimingOverride, sampleRate > 0, audioFrameCount >= sentenceEnd else {
      return sentenceEnd
    }
    let limit = min(audioFrameCount, nextSentenceStart ?? audioFrameCount)
    let available = max(0, limit - sentenceEnd)
    return sentenceEnd + min(sampleRate / 4, available)
  }
}

/// The learner-facing projection of a prepared immutable segment revision.
/// It deliberately keeps annotations opaque until their typed payload can be
/// decoded; malformed or old annotation data is never shown as invented IPA or
/// translation text.
struct ProductionPreparedSentence: Identifiable, Equatable, Sendable {
  let target: ProductionPracticeTarget
  let revision: Int
  let tokens: [TranscriptWordToken]
  let baseline: CaptionBaseline
  let annotations: [StoredPreparationAnnotation]
  var hasManualTiming: Bool = false
  /// The learner's native language; the practice service stamps it so every
  /// projection of this revision reads the same `sentence:<language>` annotation.
  var translationLanguage: TranslationLanguage = .legacyDefault

  var id: UUID { target.segmentRevisionID }
  var targetSpan: AudioSpan {
    AudioSpan(
      start: Double(target.startFrame) / Double(target.sampleRate),
      end: Double(target.endFrame) / Double(target.sampleRate))
  }

  func ipa(for token: TranscriptWordToken, accent: ReferenceAccent) -> String? {
    let key = "\(token.id):\(accent.rawValue.lowercased())"
    guard let annotation = annotations.first(where: { $0.kind == .ipa && $0.lookupKey == key })
    else { return nil }
    for data in [annotation.overrideValue, annotation.automaticValue].compactMap({ $0 }) {
      guard let value = try? JSONDecoder().decode(IPAAnnotationValue.self, from: data),
        value.accent == accent
      else { continue }
      if let ipa = value.pronunciations.first?.ipa, !ipa.isEmpty { return ipa }
    }
    return nil
  }

  /// Explicit IPA choices must drive new assessment targets as well as display.
  /// Automatic annotations remain dictionary candidates, not contextual truth.
  func ipaOverride(for token: TranscriptWordToken, accent: ReferenceAccent) -> [OfflineIPAPronunciation]? {
    let key = "\(token.id):\(accent.rawValue.lowercased())"
    guard let annotation = annotations.first(where: { $0.kind == .ipa && $0.lookupKey == key }),
      let data = annotation.overrideValue,
      let value = try? JSONDecoder().decode(IPAAnnotationValue.self, from: data),
      value.accent == accent, !value.pronunciations.isEmpty,
      value.pronunciations.allSatisfy({ !$0.ipa.isEmpty }) else { return nil }
    return value.pronunciations.map {
      .init(ipa: $0.ipa, source: "manual override · \(annotation.source)", sourceRevision: $0.sourceRevision)
    }
  }

  var translation: String? { translation(in: translationLanguage) }

  func translation(in language: TranslationLanguage) -> String? {
    guard let annotation = annotations.first(where: {
      $0.kind == .translation && $0.lookupKey == language.lookupKey
    }) else { return nil }
    for data in [annotation.overrideValue, annotation.automaticValue].compactMap({ $0 }) {
      guard let value = try? JSONDecoder().decode(SentenceTranslationValue.self, from: data),
        !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      return value.text
    }
    return nil
  }

  func lessonSentence(number: Int) -> LessonSentence {
    let sentenceSpan = targetSpan
    let words = tokens.map { token in
      LessonWord(
        id: token.id, text: token.text,
        ipaUK: ipa(for: token, accent: .uk), ipaUS: ipa(for: token, accent: .us),
        span: {
          guard let start = token.startFrame, let end = token.endFrame, end > start else {
            return nil
          }
          return AudioSpan(
            start: Double(start) / Double(target.sampleRate),
            end: Double(end) / Double(target.sampleRate))
        }(),
        needsTimingReview: token.needsTimingReview)
    }
    let baselineSpan = AudioSpan(
      start: Double(baseline.cueStartFrame) / Double(target.sampleRate),
      end: Double(baseline.cueEndFrame) / Double(target.sampleRate))
    let baselineWords = (baseline.originalTokens ?? tokens).map { token in
      LessonWord(
        id: token.id, text: token.text,
        ipaUK: ipa(for: token, accent: .uk), ipaUS: ipa(for: token, accent: .us),
        span: {
          guard let start = token.startFrame, let end = token.endFrame, end > start else {
            return nil
          }
          return AudioSpan(
            start: Double(start) / Double(target.sampleRate),
            end: Double(end) / Double(target.sampleRate))
        }(), needsTimingReview: token.needsTimingReview)
    }
    return LessonSentence(
      id: target.segmentRevisionID.uuidString, number: number, text: target.text,
      translation: translation ?? "", span: sentenceSpan,
      words: words, revision: revision,
      baseline: SentenceBaseline(
        text: target.text, translation: translation ?? "", span: baselineSpan,
        words: baselineWords))
  }

  func practiceTake(_ take: ProductionStoredTake, number: Int, sentenceNumber: Int) -> PracticeTake {
    PracticeTake(
      id: take.id.uuidString, lessonID: take.lessonID.uuidString,
      sentenceID: target.segmentRevisionID.uuidString, number: number,
      createdAt: take.createdAt,
      duration: Double(take.frameCount ?? 0) / Double(max(1, take.sampleRate ?? 1)),
      outcome: take.outcome, sourceSnapshot: lessonSentence(number: sentenceNumber),
      sourceSpeed: take.sourceSpeed, scope: target.scope, wordIDs: target.wordIDs,
      assessments: [])
  }
}

extension TranscriptWordToken: Identifiable {}

struct ProductionPracticeTargetSnapshot: Codable, Equatable, Sendable {
  let lessonID: UUID
  let lessonGeneration: Int
  let segmentID: UUID
  let segmentRevisionID: UUID
  let audioAssetID: UUID
  let sampleRate: Int
  let startFrame: Int
  let endFrame: Int
  let text: String
  let scope: PracticeScope
  let wordIDs: [String]
  var sourcePlaybackEndFrame: Int? = nil
}

struct ProductionCapturePolicy: Equatable, Sendable {
  let countdown: TimeInterval
  let trailingSilence: TimeInterval
  let maximumDuration: TimeInterval
  let speechThresholdDB: Float
  let quietThresholdDB: Float
  let minimumSpeechDuration: TimeInterval
  /// Record the full `maximumDuration` (the source sentence length) without ending early on
  /// silence, so every take matches the original timing. Trailing-silence detection is skipped.
  let fixedWindow: Bool

  init(
    countdown: TimeInterval, trailingSilence: TimeInterval,
    maximumDuration: TimeInterval, speechThresholdDB: Float = -42,
    quietThresholdDB: Float = -34, minimumSpeechDuration: TimeInterval = 0.15,
    fixedWindow: Bool = false
  ) throws {
    guard countdown.isFinite, trailingSilence.isFinite, maximumDuration.isFinite,
      countdown >= 0, trailingSilence > 0, maximumDuration > 0,
      speechThresholdDB.isFinite, quietThresholdDB.isFinite,
      minimumSpeechDuration > 0, minimumSpeechDuration <= maximumDuration
    else { throw ProductionPracticeError.invalidCapturePolicy }
    self.countdown = countdown
    self.trailingSilence = trailingSilence
    self.maximumDuration = maximumDuration
    self.speechThresholdDB = speechThresholdDB
    self.quietThresholdDB = quietThresholdDB
    self.minimumSpeechDuration = minimumSpeechDuration
    self.fixedWindow = fixedWindow
  }
}

/// Pure capture-loop decision: given the current phase and the latest level/elapsed reading,
/// says whether to finish or how to advance. Extracted so both the normal (silence-driven) and
/// fixed-window (full-duration) paths are unit-testable without the recorder or a live clock.
enum CaptureTick {
  enum Decision: Equatable {
    case finish(reachedLimit: Bool)
    case advance(phase: PracticePhase, remaining: TimeInterval)
  }

  static func decide(
    phase: PracticePhase, elapsed: TimeInterval, remaining: TimeInterval,
    delta: TimeInterval, levelDB: Float, policy: ProductionCapturePolicy
  ) -> Decision {
    if elapsed >= policy.maximumDuration { return .finish(reachedLimit: true) }
    let speaking = levelDB >= policy.speechThresholdDB
    if policy.fixedWindow {
      // Never end early: keep recording until the source-sentence duration is reached.
      let next: PracticePhase = speaking || phase != .awaitingSpeech ? .recording : .awaitingSpeech
      return .advance(phase: next, remaining: max(0, policy.maximumDuration - elapsed))
    }
    if speaking { return .advance(phase: .recording, remaining: policy.trailingSilence) }
    if phase == .recording { return .advance(phase: .trailingSilence, remaining: policy.trailingSilence) }
    if phase == .trailingSilence {
      let next = max(0, remaining - delta)
      return next == 0 ? .finish(reachedLimit: false) : .advance(phase: .trailingSilence, remaining: next)
    }
    return .advance(phase: phase, remaining: remaining)
  }
}

struct ProductionCaptureArtifact: Equatable, Sendable {
  let url: URL
  let sampleRate: Int
  let frameCount: Int
  let peakDB: Float
  let voicedFrames: Int

  var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }

  func outcome(policy: ProductionCapturePolicy, interrupted: Bool) -> CaptureOutcome {
    if interrupted { return .interrupted }
    let voicedDuration = Double(voicedFrames) / Double(sampleRate)
    if voicedDuration < policy.minimumSpeechDuration { return .noSpeech }
    if peakDB < policy.quietThresholdDB { return .quiet }
    return .complete
  }
}

struct ProductionCaptureHandle: Codable, Equatable, Sendable {
  let sessionID: UUID
  let roundID: UUID
  let takeID: UUID
  let target: ProductionPracticeTarget
  let sourceSpeed: Double
  let stagingURL: URL
  let finalURL: URL
  let manifestURL: URL
}

struct ProductionStoredTake: Identifiable, Equatable, Sendable {
  let id: UUID
  let lessonID: UUID
  let roundID: UUID
  let segmentRevisionID: UUID
  let sourceSpeed: Double
  let outcome: CaptureOutcome
  let status: String
  let relativePath: String?
  let sampleRate: Int?
  let frameCount: Int?
  let createdAt: Date
  let committedAt: Date?
}

struct ProductionTakeDeletionRecord: Equatable, Sendable {
  let takeID: UUID
  let roundID: UUID
  let sessionID: UUID
  let mediaAssetID: UUID
  let relativePath: String
}

enum MicrophoneAuthorization: Equatable, Sendable {
  case notDetermined, granted, denied, restricted
}

enum PlaybackFrameRange {
  /// Resolve seconds on this audio's own clock before checking its frame bounds.
  /// Rounding to the nearest sample absorbs floating-point addition error, not
  /// mismatched timing; an actual out-of-range frame still fails.
  static func resolve(_ span: AudioSpan, sampleRate: Int, bounds: Range<Int>) throws -> Range<Int> {
    guard sampleRate > 0, bounds.lowerBound >= 0, !bounds.isEmpty,
      span.start.isFinite, span.end.isFinite, span.start >= 0, span.end > span.start
    else { throw ProductionPracticeError.invalidPlaybackRange }
    let start = (span.start * Double(sampleRate)).rounded()
    let end = (span.end * Double(sampleRate)).rounded()
    guard start.isFinite, end.isFinite, start >= 0, end < Double(Int.max),
      start < end else { throw ProductionPracticeError.invalidPlaybackRange }
    let frames = Int(start)..<Int(end)
    guard frames.lowerBound >= bounds.lowerBound, frames.upperBound <= bounds.upperBound
    else { throw ProductionPracticeError.invalidPlaybackRange }
    return frames
  }
}

enum ProductionPracticeError: Error, Equatable, LocalizedError, Sendable, EchoCopyConvertible {
  case invalidTarget
  case invalidCapturePolicy
  case sourceUnavailable
  case invalidPlaybackRange
  case playback(String)
  case microphoneDenied
  case microphoneUnavailable
  case sourceMustBeListenedFirst
  case captureNotRunning
  case captureWrite(String)
  case persistence(String)
  case recoveryRequired(String)

  var errorDescription: String? {
    switch self {
    case .invalidTarget: "The prepared practice target is invalid."
    case .invalidCapturePolicy: "The recording timing settings are invalid."
    case .sourceUnavailable: "The local source audio is unavailable."
    case .invalidPlaybackRange: "The requested audio playback range is invalid."
    case .playback(let detail): detail
    case .microphoneDenied: "Microphone access is denied. Listening remains available."
    case .microphoneUnavailable: "No usable microphone input is available."
    case .sourceMustBeListenedFirst: "Listen to the complete source range before recording."
    case .captureNotRunning: "No recording is currently active."
    case .captureWrite(let detail): "The recording could not be written: \(detail)"
    case .persistence(let detail): "The take could not be saved: \(detail)"
    case .recoveryRequired(let detail): "Take recovery is required: \(detail)"
    }
  }

  /// Learner-facing copy in the app language; storage details stay verbatim.
  var copy: EchoCopy { presentationCopy }
  var presentationCopy: EchoCopy {
    switch self {
    case .invalidTarget: EchoCopy("practice.error.invalid_target")
    case .invalidCapturePolicy: EchoCopy("practice.error.capture_policy")
    case .sourceUnavailable: EchoCopy("practice.error.source_unavailable")
    case .invalidPlaybackRange: EchoCopy("practice.error.playback_range")
    case .playback(let detail): EchoCopy("storage.detail", arguments: [.raw(detail)])
    case .microphoneDenied: EchoCopy("practice.error.microphone_denied")
    case .microphoneUnavailable: EchoCopy("practice.error.microphone_unavailable")
    case .sourceMustBeListenedFirst: EchoCopy("practice.error.listen_first")
    case .captureNotRunning: EchoCopy("practice.error.capture_not_running")
    case .captureWrite(let detail): EchoCopy("practice.error.capture_write", arguments: [.raw(detail)])
    case .persistence(let detail): EchoCopy("practice.error.persistence", arguments: [.raw(detail)])
    case .recoveryRequired(let detail): EchoCopy("practice.error.recovery", arguments: [.raw(detail)])
    }
  }
}

extension CaptureOutcome {
  var databaseValue: String {
    switch self {
    case .complete: "complete"
    case .noSpeech: "no_speech"
    case .quiet: "quiet"
    case .earlyStop: "early_stop"
    case .interrupted: "interrupted"
    }
  }

  init?(databaseValue: String) {
    switch databaseValue {
    case "complete": self = .complete
    case "no_speech": self = .noSpeech
    case "quiet": self = .quiet
    case "early_stop": self = .earlyStop
    case "interrupted": self = .interrupted
    default: return nil
    }
  }
}
