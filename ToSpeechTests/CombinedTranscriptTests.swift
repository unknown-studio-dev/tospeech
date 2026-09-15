import Foundation
import Testing
@testable import ToSpeech

struct CombinedTranscriptTests {
  private func words(_ text: String, from: Double = 0) -> [TimedWord] {
    text.split(separator: " ").enumerated().map {
      TimedWord(text: String($0.element), start: from + Double($0.offset), end: from + Double($0.offset) + 0.5)
    }
  }
  private static let primaryProvenance = TranscriptionProvenance(engine: "FluidAudio",
    model: TranscriptionSelection.parakeet.modelID, localeIdentifier: "en", runtimeVersion: "test")
  private func prepare(_ primary: [TimedWord], _ apple: [TimedWord], captions: [CaptionCue] = [], source: TranscriptSource? = nil) throws -> [PreparedLessonSegment] {
    try CombinedTranscriptPreparation.prepare(
      primary: AudioTranscription(words: primary, source: .parakeet, provenance: Self.primaryProvenance),
      apple: AudioTranscription(words: apple, source: .appleSpeechAnalyzer,
        provenance: TranscriptionProvenance(engine: "Apple SpeechAnalyzer", model: "SpeechTranscriber", localeIdentifier: "en_GB", runtimeVersion: "test")),
      captions: captions, captionSource: source, sampleRate: 1000, frameCount: 300000)
  }
  private func baseline(_ segment: PreparedLessonSegment) throws -> CaptionBaseline {
    try JSONDecoder().decode(CaptionBaseline.self, from: Data(segment.baselineJSON.utf8))
  }

  @Test func bothASRsAgreeAndProvenanceSurvivesTimingEdit() throws {
    let segments = try prepare(words("Hello world. Goodbye world."), words("Hello world. Goodbye world."))
    #expect(segments.count == 2)
    let first = try baseline(segments[0])
    let second = try baseline(segments[1])
    #expect(first.wordTimingNeedsReview == false)
    #expect(first.reconciliation?.primary?.model == TranscriptionSelection.parakeet.modelID)
    #expect(first.reconciliation?.apple?.localeIdentifier == "en_GB")
    #expect(first.reconciliation?.captionSource == nil)
    #expect(first.originalTokens?.first?.id != second.originalTokens?.first?.id)
    #expect(first.applying(startFrame: 1, endFrame: 1000, wordTimingNeedsReview: false, resolvesTimingReview: true).reconciliation == first.reconciliation)
  }

  @Test func captionAndAppleCanCorrectAnInteriorWordButKeepReview() throws {
    let result = try prepare(words("The north wins blows."), words("The north wind blows."),
      captions: [CaptionCue(start: 0, end: 4, text: "The north wind blows.")], source: .creatorCaption)
    #expect(result[0].text == "The north wind blows.")
    let value = try baseline(result[0])
    #expect(value.wordTimingNeedsReview)
    #expect(value.originalTokens?[0].needsTimingReview == false)
    #expect(value.originalTokens?[2].needsTimingReview == true)
    #expect(value.reconciliation?.words[2].textSource == .appleSpeechAnalyzer)
    #expect(value.reconciliation?.words[2].reviewReason == "caption_apple_correction")
    #expect(value.reconciliation?.captionSource == .creatorCaption)
  }

  @Test func missingOrUnrelatedCaptionsNeverReplaceASRText() throws {
    let result = try prepare(words("The north wins blows."), words("The north wind blows."),
      captions: [CaptionCue(start: 20, end: 24, text: "The north wind blows.")], source: .automaticCaption)
    #expect(result[0].text == "The north wins blows.")
    #expect(try baseline(result[0]).wordTimingNeedsReview)
    #expect(try baseline(result[0]).reconciliation?.captionSource == nil)
  }

  @Test func partialAndRollingCaptionsDoNotDeleteIntroOrDuplicateSentences() throws {
    let stream = words("Welcome. The north wind blows. Goodbye.")
    let cues = [CaptionCue(start: 1, end: 5, text: "The north wind blows."), CaptionCue(start: 1.2, end: 5, text: "The north wind blows.")]
    let result = try prepare(stream, stream, captions: cues, source: .automaticCaption)
    #expect(result.map(\.text) == ["Welcome.", "The north wind blows.", "Goodbye."])
    #expect(try baseline(result[1]).reconciliation?.captionSource == .automaticCaption)
  }

  @Test func appleFillsOnlyMatchingMissingWordTiming() throws {
    let primary = [TimedWord(text: "Hello", start: 0, end: 0), TimedWord(text: "world.", start: 1, end: 1.5)]
    let result = try prepare(primary, words("Hello world."))
    let value = try baseline(result[0])
    #expect(value.originalTokens?[0].endFrame == 500)
    #expect(value.reconciliation?.words[0].timingSource == .appleSpeechAnalyzer)
    let different = try prepare(primary, words("Goodbye world."))
    #expect(try baseline(different[0]).originalTokens?[0].endFrame == nil)
  }

  @Test func appleInsertionAndTimingDisagreementRequireReview() throws {
    #expect(try baseline(prepare(words("Hello world."), words("Hello new world."))[0]).wordTimingNeedsReview)
    let shifted = words("Hello world.", from: 0.5)
    let result = try prepare(words("Hello world."), shifted)
    #expect(try baseline(result[0]).wordTimingNeedsReview)
  }

  @Test func captionsContradictingBothASRsRequireReview() throws {
    let result = try prepare(words("Hello world."), words("Hello world."),
      captions: [CaptionCue(start: 0, end: 2, text: "Goodbye moon.")], source: .creatorCaption)
    #expect(result[0].text == "Hello world.")
    #expect(try baseline(result[0]).wordTimingNeedsReview)
  }

  @Test func hallucinatedSentenceAfterEOFDoesNotDiscardValidTranscript() throws {
    let valid = words("Hello world.")
    let extra = [TimedWord(text: "Thank", start: 314.7, end: 314.7), TimedWord(text: "you.", start: 314.7, end: 314.82)]
    let result = try prepare(valid + extra, valid)
    #expect(result.map(\.text) == ["Hello world."])
    #expect(result[0].endFrame == 1500)
    let value = try baseline(result[0])
    #expect(value.reconciliation?.excludedWords?.map(\.text) == ["Thank", "you."])
    #expect(value.wordTimingNeedsReview)
  }

  @Test func zeroDurationSentenceInsideAudioKeepsWordsUntimedInContext() throws {
    let valid = words("Hello world.")
    let result = try prepare(valid + [TimedWord(text: "Goodbye.", start: 2, end: 2)], valid)
    #expect(result[0].text == "Hello world. Goodbye.")
    let value = try baseline(result[0])
    #expect(value.originalTokens?.last?.startFrame == nil)
    #expect(value.originalTokens?.last?.needsTimingReview == true)
    #expect(value.reconciliation?.words.last?.reviewReason == "unusable_sentence_timing")
  }

  @Test func noAudioTimelineCannotBecomeAReadyLesson() throws {
    do {
      _ = try prepare([TimedWord(text: "Hello.", start: 500, end: 501)], words("Hello."))
      Issue.record("An entirely out-of-range transcript must fail explicitly")
    } catch let error as TranscriptPreparationError {
      #expect(error.localizedDescription.contains("no sentence within"))
    }
  }

  @Test func stageCacheIsBoundToAudioModelLocaleAndRuntime() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ASRCache-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    let key = ImportTranscriptCacheIdentity(sourceChecksum: "audio1", engine: "FluidAudio", model: "parakeet-tdt-0.6b-v3", locale: "en", runtime: "0.15.7", formatVersion: 1)
    try ImportTranscriptCache.save(words("Hello world."), to: url, identity: key)
    #expect(ImportTranscriptCache.load([TimedWord].self, from: url, identity: key)?.count == 2)
    for changed in [
      ImportTranscriptCacheIdentity(sourceChecksum: "audio2", engine: key.engine, model: key.model, locale: key.locale, runtime: key.runtime, formatVersion: 1),
      ImportTranscriptCacheIdentity(sourceChecksum: key.sourceChecksum, engine: key.engine, model: "other-model", locale: key.locale, runtime: key.runtime, formatVersion: 1),
      ImportTranscriptCacheIdentity(sourceChecksum: key.sourceChecksum, engine: key.engine, model: key.model, locale: "en-US", runtime: key.runtime, formatVersion: 1),
      ImportTranscriptCacheIdentity(sourceChecksum: key.sourceChecksum, engine: key.engine, model: key.model, locale: key.locale, runtime: "new", formatVersion: 1)
    ] { #expect(ImportTranscriptCache.load([TimedWord].self, from: url, identity: changed) == nil) }
    try Data("partial JSON".utf8).write(to: url)
    #expect(ImportTranscriptCache.load([TimedWord].self, from: url, identity: key) == nil)
  }

}
