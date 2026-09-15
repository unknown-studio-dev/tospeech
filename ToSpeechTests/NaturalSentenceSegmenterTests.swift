import Foundation
import Testing

@testable import ToSpeech

struct NaturalSentenceSegmenterTests {
  private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
  }

  @Test func emptyInputReturnsNoCues() {
    #expect(NaturalSentenceSegmenter.segment([]) == [])
  }

  @Test func splitsOnSentencePunctuationOnly() {
    let words = [
      word("Hello", 0.0, 0.4), word("world.", 0.5, 0.9),
      word("How", 1.0, 1.3), word("are", 1.35, 1.5), word("you?", 1.55, 1.9),
    ]
    let options = SentenceSegmentationOptions(pauseThreshold: 5, minDuration: 0)
    let cues = NaturalSentenceSegmenter.segment(words, options: options)
    #expect(cues.map(\.text) == ["Hello world.", "How are you?"])
    #expect(cues[0].words?.count == 2)
    #expect(cues[1].words?.count == 3)
  }

  @Test func splitsOnLongPauseWhenNoPunctuation() {
    let words = [
      word("keep", 0.0, 0.4), word("going", 0.5, 0.9),
      word("then", 2.0, 2.3), word("stop", 2.35, 2.7),
    ]
    let options = SentenceSegmentationOptions(pauseThreshold: 0.6, minDuration: 0)
    let cues = NaturalSentenceSegmenter.segment(words, options: options)
    #expect(cues.map(\.text) == ["keep going", "then stop"])
    #expect(cues[0].start == 0.0)
    #expect(cues[0].end == 0.9)
  }

  @Test func mergesTooShortSegments() {
    // Mỗi từ thành 1 nhóm ở pass 1 (ngưỡng nghỉ cực nhỏ), rồi gộp tới >= minDuration.
    let words = [
      word("a", 0.0, 0.7), word("b", 0.8, 1.5),
      word("c", 1.6, 2.3), word("d", 2.4, 3.1),
    ]
    let options = SentenceSegmentationOptions(pauseThreshold: 0.0001, minDuration: 1.2)
    let cues = NaturalSentenceSegmenter.segment(words, options: options)
    #expect(cues.map(\.text) == ["a b", "c d"])
  }

  @Test func keepsALongPauselessSentenceWholeInsteadOfShreddingIt() {
    // A slow sentence read with no silence between words — every word touches
    // the next (end[i] == start[i+1]) — and no internal sentence punctuation.
    // There is no boundary to cut on, so it stays one cue however long it runs.
    // (This is the "their / foothold / at / street" shredding bug: a length cap
    // used to force-split it one word at a time.)
    let words = (0..<12).map { index -> TimedWord in
      let start = Double(index) * 1.5
      return word("w\(index)", start, start + 1.5)
    }
    let cues = NaturalSentenceSegmenter.segment(
      words, options: SentenceSegmentationOptions(pauseThreshold: 0.6, minDuration: 0))
    #expect(cues.count == 1)
    #expect(cues[0].words?.count == 12)
    #expect(cues[0].start == 0.0)
    #expect(cues[0].end == 18.0)
  }

  @Test func stillCutsALongRunWhereTheSpeakerActuallyPauses() {
    // Two sentences' worth of words with a real 1.1s pause between them and no
    // punctuation: the pause — not any length rule — is the boundary.
    let words = [
      word("fog", 0.0, 1.5), word("everywhere", 1.5, 3.0), word("over", 3.0, 4.5),
      word("london", 5.6, 7.1), word("creeping", 7.1, 8.6), word("upriver", 8.6, 10.1),
    ]
    let cues = NaturalSentenceSegmenter.segment(
      words, options: SentenceSegmentationOptions(pauseThreshold: 0.6, minDuration: 0))
    #expect(cues.map(\.text) == ["fog everywhere over", "london creeping upriver"])
  }

  @Test func mapsGroupIntoCueWithWordSpans() {
    let words = [word("Hello", 1.0, 1.5), word("world.", 1.6, 2.2)]
    let cues = NaturalSentenceSegmenter.segment(
      words, options: SentenceSegmentationOptions(pauseThreshold: 5, minDuration: 0))
    #expect(cues.count == 1)
    #expect(cues[0].start == 1.0)
    #expect(cues[0].end == 2.2)
    #expect(cues[0].text == "Hello world.")
    #expect(
      cues[0].words == [
        CaptionWord(text: "Hello", start: 1.0, end: 1.5),
        CaptionWord(text: "world.", start: 1.6, end: 2.2),
      ])
  }
}
