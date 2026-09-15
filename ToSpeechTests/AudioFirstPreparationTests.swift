import Foundation
import Testing
import Speech
import CoreMedia

@testable import ToSpeech

struct AudioFirstPreparationTests {
  @Test func sentenceImportKeepsReadingPausesAndNormalizesSpacing() {
    let cues = NaturalSentenceSegmenter.segment([
      word(" pronunciation", 0, 0.4), word(",", 0.4, 0.4),
      word(" intonation", 1.3, 1.7), word(" and", 1.8, 2), word(" accent.", 2.1, 2.5),
      word(" Next", 3, 3.4), word(" sentence.", 3.4, 4)])
    #expect(cues.map(\.text) == ["pronunciation, intonation and accent.", "Next sentence."])
    #expect(cues[0].start == 0 && cues[0].end == 2.5)
    #expect(cues[0].words?.map(\.text) == ["pronunciation", ",", "intonation", "and", "accent."])
    #expect(TranscriptText.join([" I", "'m", " here", "."]) == "I'm here.")
  }

  @Test func sentenceTokenizerDoesNotSplitAnEnglishTitle() {
    let words = ["Dr.", "Smith", "is", "here.", "Hello!"]
      .enumerated().map { word($0.element, Double($0.offset), Double($0.offset) + 0.5) }
    #expect(NaturalSentenceSegmenter.segment(words).map(\.text) == ["Dr. Smith is here.", "Hello!"])
  }

  @Test func appleAttributesKeepMeasuredWordTimingAndDoNotInventPhraseTiming() {
    var one = AttributedString(" Hello")
    one.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 16000), duration: CMTime(seconds: 0.5, preferredTimescale: 16000))
    var phrase = AttributedString(" new words")
    phrase.audioTimeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 16000), duration: CMTime(seconds: 1, preferredTimescale: 16000))
    let text = one + AttributedString(" unknown") + phrase
    let words = AppleSpeechAnalyzerTranscriber.timedWords(from: text, fallbackStart: 1)
    #expect(words.map(\.text) == ["Hello", "unknown", "new", "words"])
    #expect(words[0].start == 1 && words[0].end == 1.5)
    #expect(words.dropFirst().allSatisfy { $0.start == $0.end })
  }

  @Test func appleProvenanceAndMissingTimingSurvivePreparationAndRevision() throws {
    let provenance = TranscriptionProvenance(engine: "Apple SpeechAnalyzer", model: "SpeechTranscriber", localeIdentifier: "en_GB", runtimeVersion: "test OS")
    let transcript = AudioTranscription(
      words: [word(" Hello", 0, 0.5), word(" uncertain", 0.5, 0.5), word(" world.", 0.6, 1)],
      source: .appleSpeechAnalyzer, provenance: provenance)
    let segment = try #require(AudioFirstPreparation.prepareSegments(transcript: transcript, sampleRate: 16000, frameCount: 32000).first)
    let baseline = try JSONDecoder().decode(CaptionBaseline.self, from: Data(segment.baselineJSON.utf8))
    #expect(baseline.transcription == provenance)
    #expect(baseline.source == .appleSpeechAnalyzer)
    #expect(baseline.wordTimingNeedsReview)
    #expect(baseline.originalTokens?[1].startFrame == nil)
    let revised = baseline.applying(startFrame: 0, endFrame: 16000, wordTimingNeedsReview: false, resolvesTimingReview: true, timingTranscription: provenance)
    #expect(revised.transcription == provenance)
    #expect(revised.timingTranscription == provenance)
    #expect(revised.applying(startFrame: 1, endFrame: 15999, wordTimingNeedsReview: false, resolvesTimingReview: true).timingTranscription == provenance)
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(segment.baselineJSON.utf8)) as? [String: Any])
    legacy.removeValue(forKey: "transcription")
    #expect(try JSONDecoder().decode(CaptionBaseline.self, from: JSONSerialization.data(withJSONObject: legacy)).transcription == nil)
  }

  @Test func invalidOrPunctuationTimingIsNotPretendedToBeAValidWordRange() throws {
    let segment = try #require(CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Hello, broken.", words: [
        CaptionWord(text: "Hello", start: 0, end: 0.4),
        CaptionWord(text: ",", start: 0.4, end: 0.4),
        CaptionWord(text: "broken.", start: .nan, end: 0.9)])],
      source: .appleSpeechAnalyzer, sampleRate: 16000, frameCount: 16000).first)
    let tokens = try JSONDecoder().decode([TranscriptWordToken].self, from: Data(segment.tokensJSON.utf8))
    #expect(tokens[0].startFrame == 0)
    #expect(!tokens[1].needsTimingReview)
    #expect(tokens[2].startFrame == nil && tokens[2].needsTimingReview)
  }

  @Test func aCaptionSubstitutionCannotBorrowUnrelatedWordTiming() {
    let result = AudioFirstPreparation.reconciledWords(captionText: "cat", asrWords: [word("dog", 1, 2)])
    #expect(result[0].start == result[0].end)
  }

  private func word(_ t: String, _ s: Double, _ e: Double) -> TimedWord {
    TimedWord(text: t, start: s, end: e)
  }
  @Test func reconciledWordsBorrowAsrTimingAndFlagUnmatched() {
    let asr = [word("hello", 0.0, 0.4), word("world", 0.5, 0.9)]
    let words = AudioFirstPreparation.reconciledWords(
      captionText: "Hello brave world", asrWords: asr)
    #expect(words.map(\.text) == ["Hello", "brave", "world"])
    #expect(words[0].start == 0.0 && words[0].end == 0.4)
    #expect(words[1].start == words[1].end)
    #expect(words[2].start == 0.5 && words[2].end == 0.9)
  }

  @Test func pureASRProducesNaturalSentences() async throws {
    let asr = [
      word("Hello", 0.0, 0.4), word("world.", 0.5, 0.9),
      word("How", 1.0, 1.3), word("are", 1.35, 1.5), word("you?", 1.55, 1.9),
    ]
    let segments = try await AudioFirstPreparation.prepareSegments(
      audioURL: URL(fileURLWithPath: "/dev/null"), captionText: nil,
      sampleRate: 16_000, frameCount: 16_000 * 10,
      options: SentenceSegmentationOptions(pauseThreshold: 5, minDuration: 0),
      transcribe: { _ in asr })
    #expect(segments.map(\.text) == ["Hello world.", "How are you?"])
  }

  @Test func captionTextReplacesAsrSpelling() async throws {
    let asr = [word("im", 0.0, 0.4), word("fine.", 0.5, 0.9)]
    let segments = try await AudioFirstPreparation.prepareSegments(
      audioURL: URL(fileURLWithPath: "/dev/null"), captionText: "I'm fine.",
      sampleRate: 16_000, frameCount: 16_000 * 10,
      options: SentenceSegmentationOptions(pauseThreshold: 5, minDuration: 0),
      transcribe: { _ in asr })
    #expect(segments.count == 1)
    #expect(segments[0].text == "I'm fine.")
  }

  @Test func emptyTranscriptThrows() async {
    await #expect(throws: CaptionTranscriptError.self) {
      _ = try await AudioFirstPreparation.prepareSegments(
        audioURL: URL(fileURLWithPath: "/dev/null"), captionText: nil,
        sampleRate: 16_000, frameCount: 16_000,
        transcribe: { _ in [] })
    }
  }
}
