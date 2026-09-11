import Foundation

/// An explicit choice must be installed; never silently substitute another model.
/// With no saved choice, use the default installed variant, then catalog order.
enum WhisperModelSelection {
  static func active(from releases: [EngineReleaseRecord], selected: String? = nil) -> WhisperModelVariant? {
    let installed = releases
      .filter { $0.status == "installed" }
      .compactMap { record in
        WhisperModelCatalog.all.first { $0.whisperKitModel == record.version }
      }
    if let selected {
      guard let variant = WhisperModelVariant(rawValue: selected), installed.contains(variant) else { return nil }
      return variant
    }
    if installed.contains(.default) { return .default }
    return WhisperModelCatalog.all.first { installed.contains($0) }
  }
}

/// Audio-first preparation: ASR word timings drive both sentence cutting and
/// (optionally) reconciliation with clean caption text. Pure logic; the ASR
/// call is injected so this is unit-testable without a model.
enum AudioFirstPreparation {
  static func reconciledWords(captionText: String, asrWords: [TimedWord]) -> [TimedWord] {
    let tokens = captionText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let aligned = TranscriptAligner.align(reference: tokens, timed: asrWords)
    var lastEnd = asrWords.first?.start ?? 0
    return aligned.map { word in
      if word.isMatched, let start = word.start, let end = word.end {
        lastEnd = end
        return TimedWord(text: word.text, start: start, end: end)
      }
      return TimedWord(text: word.text, start: lastEnd, end: lastEnd)
    }
  }

  static func prepareSegments(
    transcript: AudioTranscription, sampleRate: Int, frameCount: Int
  ) throws -> [PreparedLessonSegment] {
    let cues = NaturalSentenceSegmenter.segment(transcript.words)
    return try CaptionTranscriptBuilder.build(
      cues: cues, source: transcript.source, sampleRate: sampleRate, frameCount: frameCount,
      provenance: transcript.provenance)
  }

  static func prepareSegments(
    audioURL: URL, captionText: String?, variant: WhisperModelVariant,
    sampleRate: Int, frameCount: Int, options: SentenceSegmentationOptions = .default,
    transcribe: (URL, WhisperModelVariant) async throws -> [TimedWord]
  ) async throws -> [PreparedLessonSegment] {
    let asrWords = try await transcribe(audioURL, variant)
    guard !asrWords.isEmpty else { throw CaptionTranscriptError.noUsableCues }
    let stream: [TimedWord]
    let source: TranscriptSource
    if let captionText,
      !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      stream = reconciledWords(captionText: captionText, asrWords: asrWords)
      source = .automaticCaption
    } else {
      stream = asrWords
      source = .whisper
    }
    let cues = NaturalSentenceSegmenter.segment(stream, options: options)
    return try CaptionTranscriptBuilder.build(
      cues: cues, source: source, sampleRate: sampleRate, frameCount: frameCount)
  }
}
