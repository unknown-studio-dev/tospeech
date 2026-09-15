import Foundation
import NaturalLanguage
@preconcurrency import Speech

enum AppleSpeechCaptionError: Error, Equatable, LocalizedError, Sendable {
  case permissionDenied
  case onDeviceRecognitionUnavailable
  case recognizerUnavailable
  case noTranscription
  case recognitionFailed(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .timedOut: "Apple Speech timed out. Please try again."
    case .permissionDenied: "Speech recognition permission is required to prepare this lesson."
    case .onDeviceRecognitionUnavailable:
      "English on-device speech recognition is not installed on this Mac."
    case .recognizerUnavailable: "English speech recognition is unavailable right now."
    case .noTranscription: "Apple Speech did not return a usable transcript."
    case .recognitionFailed(let detail): "Apple Speech could not prepare the transcript: \(detail)"
    }
  }
}

/// Last-resort local caption source. `requiresOnDeviceRecognition` stays true:
/// this importer never turns an unavailable local model into a cloud request.
@MainActor
enum AppleSpeechCaptionTranscriber {
  /// Caption verification must not surprise a user with a permission prompt.
  /// Imports without captions call `transcribe` instead, which may request consent.
  static func isAvailableWithoutRequestingPermission(
    locale: Locale = Locale(identifier: "en_US")
  ) -> Bool {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
      let recognizer = SFSpeechRecognizer(locale: locale)
    else { return false }
    return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
  }

  static func transcribe(
    audioURL: URL, locale: Locale = Locale(identifier: "en_US")
  ) async throws -> [CaptionCue] {
    let authorization = try await authorizationStatus()
    guard authorization == .authorized else { throw AppleSpeechCaptionError.permissionDenied }
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw AppleSpeechCaptionError.recognizerUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw AppleSpeechCaptionError.onDeviceRecognitionUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    let sentenceCues = try await recognize(with: recognizer, request: request)
    guard !sentenceCues.isEmpty else { throw AppleSpeechCaptionError.noTranscription }
    return sentenceCues
  }

  static func authorizationStatus(
    current: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus(),
    request: (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = {
      SFSpeechRecognizer.requestAuthorization($0)
    }
  ) async throws -> SFSpeechRecognizerAuthorizationStatus {
    guard current == .notDetermined else { return current }
    return try await SpeechCallbackOperation<SFSpeechRecognizerAuthorizationStatus>().value { completion in
      // Explicitly Sendable: TCC invokes this on a background queue, not MainActor.
      request { @Sendable status in completion(.success(status)) }
      return nil
    }
  }

  private static func recognize(
    with recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest
  ) async throws -> [CaptionCue] {
    try await SpeechCallbackOperation<[CaptionCue]>().value(timeout: .seconds(120)) { completion in
      let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
        if let error {
          completion(.failure(AppleSpeechCaptionError.recognitionFailed(error.localizedDescription)))
        } else if let result, result.isFinal {
          completion(.success(sentenceCues(from: result.bestTranscription)))
        }
      }
      // Keep the task alive until a terminal result, cancellation or timeout.
      return { task.cancel() }
    }
  }

  nonisolated private static func sentenceCues(from transcription: SFTranscription) -> [CaptionCue] {
    let fullText = transcription.formattedString
    let segments = transcription.segments
    guard !fullText.isEmpty, !segments.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = fullText
    var cues: [CaptionCue] = []
    tokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { range, _ in
      let sentenceRange = NSRange(range, in: fullText)
      let words = segments.compactMap { segment -> CaptionWord? in
        let segmentRange = segment.substringRange
        guard NSIntersectionRange(sentenceRange, segmentRange).length > 0 else { return nil }
        let end = segment.timestamp + segment.duration
        guard segment.duration > 0, end > segment.timestamp else { return nil }
        return CaptionWord(text: segment.substring, start: segment.timestamp, end: end)
      }
      guard let start = words.map(\.start).min(), let end = words.map(\.end).max(), end > start
      else {
        return true
      }
      cues.append(
        CaptionCue(
          start: start, end: end,
          text: String(fullText[range]).trimmingCharacters(in: .whitespacesAndNewlines),
          words: words))
      return true
    }
    if !cues.isEmpty { return cues }
    let words = segments.compactMap { segment -> CaptionWord? in
      let end = segment.timestamp + segment.duration
      guard segment.duration > 0, end > segment.timestamp else { return nil }
      return CaptionWord(text: segment.substring, start: segment.timestamp, end: end)
    }
    guard let start = words.map(\.start).min(), let end = words.map(\.end).max(), end > start else {
      return []
    }
    return [CaptionCue(start: start, end: end, text: fullText, words: words)]
  }
}

/// One-time upgrade path for lessons imported before caption word alignment was
/// available. It publishes immutable timing revisions and preserves any manual
/// timing already present on individual tokens.
@MainActor
final class AppleSpeechWordTimingPreparer: WordTimingPreparing {
  private let service: ProductionPracticeService
  private let transcribe: @MainActor (URL) async throws -> [CaptionCue]
  private let audioTranscriber: (any AudioTranscriptTranscribing)?

  init(
    service: ProductionPracticeService,
    audioTranscriber: (any AudioTranscriptTranscribing)? = nil,
    transcribe: @escaping @MainActor (URL) async throws -> [CaptionCue] = {
      try await AppleSpeechCaptionTranscriber.transcribe(audioURL: $0)
    }
  ) {
    self.service = service
    self.transcribe = transcribe
    self.audioTranscriber = audioTranscriber
  }

  @discardableResult
  func prepare(sentences: [ProductionPreparedSentence], localeIdentifier: String = "en-GB") async throws -> Bool {
    guard let first = sentences.first,
      sentences.contains(where: { sentence in
        sentence.tokens.contains { token in
          IPAFormatting.isPronounceable(token.text)
            && (token.startFrame == nil || token.endFrame == nil || token.needsTimingReview)
        }
      })
    else { return false }

    let speechCues: [CaptionCue]
    let provenance: TranscriptionProvenance?
    if let audioTranscriber {
      let result = try await audioTranscriber.transcribe(
        audioURL: first.target.audioURL, localeIdentifier: localeIdentifier, onProgress: { _ in })
      speechCues = NaturalSentenceSegmenter.segment(result.words)
      provenance = result.provenance
    } else {
      speechCues = try await transcribe(first.target.audioURL)
      provenance = nil
    }
    try Task.checkCancellation()
    var published = false
    for sentence in sentences {
      try Task.checkCancellation()
      let sampleRate = sentence.target.sampleRate
      let cueStart = Double(sentence.target.startFrame) / Double(sampleRate)
      let cueEnd = Double(sentence.target.endFrame) / Double(sampleRate)
      let aligned = CaptionWordTimingAligner.alignedWords(
        for: sentence.tokens.map(\.text), cueStart: cueStart, cueEnd: cueEnd,
        speechCues: speechCues)
      var changed = false
      let tokens = zip(sentence.tokens, aligned).map { token, evidence in
        if token.startFrame != nil, token.endFrame != nil, !token.needsTimingReview {
          return token
        }
        guard let evidence else { return token }
        let start = Int((evidence.start * Double(sampleRate)).rounded())
        let end = Int((evidence.end * Double(sampleRate)).rounded())
        guard start >= sentence.target.startFrame, end > start, end <= sentence.target.endFrame
        else { return token }
        changed = true
        return TranscriptWordToken(
          id: token.id, text: token.text, startFrame: start, endFrame: end,
          needsTimingReview: false)
      }
      guard changed else { continue }
      let complete = tokens.filter { IPAFormatting.isPronounceable($0.text) }.allSatisfy { token in
        guard let start = token.startFrame, let end = token.endFrame else { return false }
        return start >= sentence.target.startFrame && end > start && end <= sentence.target.endFrame
          && !token.needsTimingReview
      }
      _ = try await service.publishTimingRevision(
        SegmentTimingRevisionDraft(
          segmentID: sentence.target.segmentID,
          expectedRevisionID: sentence.target.segmentRevisionID,
          startFrame: sentence.target.startFrame, endFrame: sentence.target.endFrame,
          tokens: tokens,
          resolvesTimingReview: complete && sentence.baseline.timingReviewReason == nil,
          timingTranscription: provenance))
      published = true
    }
    return published
  }
}

/// Serializes arbitrary framework callbacks, cancellation and timeout on MainActor.
/// Only the first terminal event can resume the continuation.
@MainActor
final class SpeechCallbackOperation<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, any Error>?
  private var cancelWork: (@MainActor () -> Void)?
  private var deadline: Task<Void, Never>?
  private var finished = false

  func value(
    timeout: Duration? = nil,
    start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> (@MainActor () -> Void)?
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        cancelWork = start { @Sendable result in
          Task { @MainActor in self.finish(result) }
        }
        if let timeout {
          deadline = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            finish(.failure(AppleSpeechCaptionError.timedOut))
          }
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func finish(_ result: Result<Value, any Error>) {
    guard !finished else { return }
    finished = true
    let continuation = continuation
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    let cancel = cancelWork
    cancelWork = nil
    cancel?()
    continuation?.resume(with: result)
  }
}
