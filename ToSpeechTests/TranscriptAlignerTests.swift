import Foundation
import Testing

@testable import ToSpeech

struct TranscriptAlignerTests {
  private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
  }

  @Test func identicalTokensAllMatchWithTiming() {
    let result = TranscriptAligner.align(
      reference: ["Hello", "world"],
      timed: [word("Hello", 0.0, 0.5), word("world", 0.6, 1.0)])
    #expect(
      result == [
        AlignedWord(text: "Hello", start: 0.0, end: 0.5, isMatched: true, candidateText: "Hello"),
        AlignedWord(text: "world", start: 0.6, end: 1.0, isMatched: true, candidateText: "world"),
      ])
  }

  @Test func insertedReferenceWordGetsNoTiming() {
    let result = TranscriptAligner.align(
      reference: ["Hello", "brave", "world"],
      timed: [word("Hello", 0.0, 0.5), word("world", 0.6, 1.0)])
    #expect(result.map(\.text) == ["Hello", "brave", "world"])
    #expect(result[1] == AlignedWord(text: "brave", start: nil, end: nil, isMatched: false))
    #expect(result[2] == AlignedWord(text: "world", start: 0.6, end: 1.0, isMatched: true, candidateText: "world"))
  }

  @Test func asrExtraWordIsDropped() {
    let result = TranscriptAligner.align(
      reference: ["Hello", "world"],
      timed: [word("Hello", 0.0, 0.5), word("there", 0.55, 0.8), word("world", 0.9, 1.2)])
    #expect(result.count == 2)
    #expect(result[1] == AlignedWord(text: "world", start: 0.9, end: 1.2, isMatched: true, candidateText: "world"))
  }

  @Test func substitutionKeepsReferenceTextButAsrTiming() {
    let result = TranscriptAligner.align(
      reference: ["say", "brave", "now"],
      timed: [word("say", 0.0, 0.4), word("grave", 0.5, 0.9), word("now", 1.0, 1.3)])
    #expect(result[1] == AlignedWord(text: "brave", start: 0.5, end: 0.9, isMatched: false, candidateText: "grave"))
    #expect(result[0].isMatched && result[2].isMatched)
  }

  @Test func normalizationIgnoresCaseAndPunctuation() {
    let result = TranscriptAligner.align(
      reference: ["Hello,"], timed: [word("hello", 0.0, 0.5)])
    #expect(result == [AlignedWord(text: "Hello,", start: 0.0, end: 0.5, isMatched: true, candidateText: "hello")])
  }

  @Test func emptyInputsBehave() {
    #expect(TranscriptAligner.align(reference: [], timed: [word("x", 0, 1)]) == [])
    let noTiming = TranscriptAligner.align(reference: ["a", "b"], timed: [])
    #expect(
      noTiming == [
        AlignedWord(text: "a", start: nil, end: nil, isMatched: false),
        AlignedWord(text: "b", start: nil, end: nil, isMatched: false),
      ])
  }
}
