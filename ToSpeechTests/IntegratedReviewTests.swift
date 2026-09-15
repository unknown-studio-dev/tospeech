import Foundation
import Testing
@testable import ToSpeech

@Suite struct IntegratedReviewTests {
  @Test func comparisonAcceptsRoundedSentenceEndAndIndependentLongerRecording() throws {
    let offset = 0.16, sourceDuration = 3.12
    #expect(offset + sourceDuration > 3.28) // Reproduces the rejected saved result.
    let source = try PlaybackFrameRange.resolve(.init(start: offset, end: offset + sourceDuration),
      sampleRate: 48_000, bounds: 7_680..<157_440)
    let take = try PlaybackFrameRange.resolve(.init(start: 0, end: 6.4),
      sampleRate: 48_000, bounds: 0..<307_200)
    #expect(source == 7_680..<157_440)
    #expect(take == 0..<307_200)
  }

  @Test func delayedWordsUseTheirOwnRecordingClockAndSampleRate() throws {
    let source = try PlaybackFrameRange.resolve(.init(start: 0.66, end: 0.92),
      sampleRate: 48_000, bounds: 7_680..<157_440)
    let take = try PlaybackFrameRange.resolve(.init(start: 1.22, end: 1.365),
      sampleRate: 44_100, bounds: 0..<282_240)
    #expect(source == 31_680..<44_160)
    #expect(take == 53_802..<60_197)
    let shorterTake = try PlaybackFrameRange.resolve(.init(start: 0.1, end: 0.4),
      sampleRate: 16_000, bounds: 0..<8_000)
    #expect(shorterTake == 1_600..<6_400)
  }

  @Test func playbackRejectsRealOverflowAndMalformedSpansWithoutClamping() {
    for span in [AudioSpan(start: 0.16, end: 3.28 + 1.0/48_000),
      .init(start: 0.16 - 1.0/48_000, end: 3.28),
      .init(start: 0.16, end: 6.4), .init(start: .nan, end: 1),
      .init(start: 0.16, end: .infinity), .init(start: 0.16, end: 1e308),
      .init(start: 0.5, end: 0.5), .init(start: 0.8, end: 0.2)] {
      #expect(throws: ProductionPracticeError.invalidPlaybackRange) {
        try PlaybackFrameRange.resolve(span, sampleRate: 48_000, bounds: 7_680..<157_440)
      }
    }
  }

  private func word(_ ipa: String, phones: [PhoneDifference], supported: Bool = true) -> WordPronunciationEvidence {
    .init(target: .init(id: "word", text: "word", variants: [ipa], dictionarySources: [], sourceStart: 0, sourceEnd: 1),
      referenceIPA: ipa, phones: phones, supported: supported)
  }
  @Test func continuousIPAPreservesNotationAndGradesOnlyPhones() {
    let evidence = word("ˈθɔːt", phones: [
      .init(id: 0, kind: .substitution, expected: "θ", observed: "t", start: 0, end: 0.1, quality: .incorrect),
      .init(id: 1, kind: .substitution, expected: "ɔ", observed: "ɑ", start: 0.1, end: 0.2, quality: .nearCorrect),
      .init(id: 2, kind: .matched, expected: "t", observed: "t", start: 0.2, end: 0.3, quality: .correct)])
    let runs = PronunciationDisplay.runs(ipa: evidence.referenceIPA, word: evidence)
    #expect(runs.map(\.text).joined() == "/ˈθɔːt/")
    #expect(runs.filter { $0.phoneID != nil }.map(\.quality) == [.incorrect, .nearCorrect, .correct])
    #expect(runs.first { $0.text == "ː" }?.quality == .unassessed)
  }
  @Test func uncertaintyIsNeverPaintedYellowOrGreen() {
    for kind in [PhoneDifference.Kind.uncertain, .referenceUncertain] {
      let phone = PhoneDifference(id: 0, kind: kind, expected: "ɪ", observed: "i", start: 0, end: 1, quality: .nearCorrect)
      #expect(PronunciationQualityPolicy.quality(for: phone) == .unassessed)
      #expect(PronunciationDisplay.quality(phone, supported: true) == .unassessed)
    }
  }
  @Test func nearCategoryIsIndependentOfPosteriorConfidence() throws {
    let target = word("bɪt", phones: []).target
    for posterior in [0.3, 0.99] {
      let heard = ["b", "i", "t"].enumerated().map {
        RecognizedPhone(symbol: $0.element, start: Double($0.offset)*0.1, end: Double($0.offset+1)*0.1, posterior: posterior)
      }
      let result = try PronunciationComparison.compare(targets: [target], heard: heard, duration: 1)
      #expect(result.words[0].phones[1].quality == (posterior < 0.6 ? .unassessed : .nearCorrect))
    }
  }
  @Test func malformedOrDifferentIPAHasNoMisplacedHighlights() {
    let evidence = word("kæt", phones: [.init(id: 0, kind: .matched, expected: "k", observed: "k", start: 0, end: 1)])
    #expect(PronunciationDisplay.runs(ipa: "kæt", word: evidence).allSatisfy { $0.quality == .unassessed && $0.phoneID == nil })
    #expect(PronunciationDisplay.runs(ipa: "☃", word: evidence).map(\.text).joined() == "/☃/")
  }
  @Test func insertionDoesNotShiftTheExpectedIPA() {
    let evidence = word("æ", phones: [
      .init(id: 0, kind: .insertion, expected: nil, observed: "k", start: 0, end: 0.1),
      .init(id: 1, kind: .matched, expected: "æ", observed: "æ", start: 0.1, end: 0.2)])
    let run = PronunciationDisplay.runs(ipa: "æ", word: evidence).first { $0.phoneID != nil }
    #expect(run?.text == "æ" && run?.phoneID == 1 && run?.quality == .correct)
  }
  @Test func legacyResultsDecodeWithoutInventingNewGrades() throws {
    let data = Data(#"{"id":0,"kind":"substitution","expected":"ɪ","observed":"i","start":0,"end":1}"#.utf8)
    let phone = try JSONDecoder().decode(PhoneDifference.self, from: data)
    #expect(phone.quality == nil)
    #expect(PronunciationDisplay.quality(phone, supported: true) == .incorrect)
  }
  @Test func RPShortEUsesTheRecognizersVowelCategory() {
    #expect(PhoneInventory.parse("/welkəm/") != nil)
    #expect(PhoneInventory.canonical("e") == PhoneInventory.canonical("ɛ"))
  }
  @Test func measuredPitchIsRelativeToEachSpeaker() throws {
    let a = try AcousticDeliveryAnalyzer.track(samples: tone(hz: 120, amplitude: 0.25))
    let b = try AcousticDeliveryAnalyzer.track(samples: tone(hz: 220, amplitude: 0.5))
    #expect(a.pitchFrames > 20 && b.pitchFrames > 20)
    #expect(a.frames.compactMap(\.pitchSemitones).allSatisfy { abs($0) < 0.3 })
    #expect(b.frames.compactMap(\.pitchSemitones).allSatisfy { abs($0) < 0.3 })
    #expect(a.pauses.isEmpty && b.pauses.isEmpty)
  }
  @Test func silenceDoesNotBecomeAFlatPitchCurve() throws {
    let result = try AcousticDeliveryAnalyzer.track(samples: Array(repeating: 0, count: 16_000))
    #expect(result.activeSpan == nil)
    #expect(result.pitchFrames == 0 && result.pauses.isEmpty)
  }
  @Test func internalPauseExcludesLeadingAndTrailingSilence() throws {
    let silence = Array(repeating: Float(0), count: 8_000)
    let result = try AcousticDeliveryAnalyzer.track(samples: silence + tone(hz: 160) + silence + tone(hz: 160) + silence)
    #expect(result.pauses.count == 1)
    #expect(result.pauses[0].duration > 0.35)
    #expect(result.activeSpan!.start > 0.4 && result.activeSpan!.end < result.duration-0.4)
  }
  @Test func invalidAudioIsRejectedBeforeDSP() {
    #expect(throws: BuddyError.self) { try AcousticDeliveryAnalyzer.track(samples: [.nan]) }
    #expect(throws: BuddyError.self) { try AcousticDeliveryAnalyzer.track(samples: Array(repeating: 0, count: 480_001)) }
  }
  private func tone(hz: Double, amplitude: Double = 0.3) -> [Float] {
    (0..<16_000).map { Float(amplitude*sin(2 * .pi * hz * Double($0)/16_000)) }
  }
}
