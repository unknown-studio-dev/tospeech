import Foundation
import NaturalLanguage
@preconcurrency import Speech

enum AppleSpeechCaptionError: Error, Equatable, LocalizedError, Sendable {
  case permissionDenied
  case onDeviceRecognitionUnavailable
  case recognizerUnavailable
  case noTranscription
  case recognitionFailed(String)

  var errorDescription: String? {
    switch self {
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
    let authorization = await authorizationStatus()
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
    let transcription = try await recognize(with: recognizer, request: request)
    let sentenceCues = sentenceCues(from: transcription)
    guard !sentenceCues.isEmpty else { throw AppleSpeechCaptionError.noTranscription }
    return sentenceCues
  }

  private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
    let existing = SFSpeechRecognizer.authorizationStatus()
    guard existing == .notDetermined else { return existing }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  private static func recognize(
    with recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest
  ) async throws -> SFTranscription {
    try await withCheckedThrowingContinuation { continuation in
      _ = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          continuation.resume(
            throwing: AppleSpeechCaptionError.recognitionFailed(error.localizedDescription))
        } else if let result, result.isFinal {
          continuation.resume(returning: result.bestTranscription)
        }
      }
    }
  }

  private static func sentenceCues(from transcription: SFTranscription) -> [CaptionCue] {
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
final class AppleSpeechWordTimingPreparer {
  private let service: ProductionPracticeService

  init(service: ProductionPracticeService) { self.service = service }

  @discardableResult
  func prepare(sentences: [ProductionPreparedSentence]) async throws -> Bool {
    guard let first = sentences.first,
      sentences.contains(where: { sentence in
        sentence.tokens.contains { token in
          token.startFrame == nil || token.endFrame == nil || token.needsTimingReview
        }
      })
    else { return false }

    let speechCues = try await AppleSpeechCaptionTranscriber.transcribe(
      audioURL: first.target.audioURL)
    var published = false
    for sentence in sentences {
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
      let complete = tokens.allSatisfy { token in
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
          resolvesTimingReview: complete && sentence.baseline.timingReviewReason == nil))
      published = true
    }
    return published
  }
}
