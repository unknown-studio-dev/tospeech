import Foundation

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
    audioURL: URL, captionText: String?, source: TranscriptSource = .parakeet,
    sampleRate: Int, frameCount: Int, options: SentenceSegmentationOptions = .default,
    transcribe: (URL) async throws -> [TimedWord]
  ) async throws -> [PreparedLessonSegment] {
    let asrWords = try await transcribe(audioURL)
    guard !asrWords.isEmpty else { throw CaptionTranscriptError.noUsableCues }
    let stream: [TimedWord]
    let cueSource: TranscriptSource
    if let captionText,
      !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      stream = reconciledWords(captionText: captionText, asrWords: asrWords)
      cueSource = .automaticCaption
    } else {
      stream = asrWords
      cueSource = source
    }
    let cues = NaturalSentenceSegmenter.segment(stream, options: options)
    return try CaptionTranscriptBuilder.build(
      cues: cues, source: cueSource, sampleRate: sampleRate, frameCount: frameCount)
  }
}
