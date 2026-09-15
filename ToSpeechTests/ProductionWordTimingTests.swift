import Foundation
import Testing
@testable import ToSpeech

struct ProductionWordTimingTests {
  private var target: ProductionPracticeTarget {
    ProductionPracticeTarget(lessonID: UUID(), lessonGeneration: 1, segmentID: UUID(),
      segmentRevisionID: UUID(), audioAssetID: UUID(), audioURL: URL(fileURLWithPath: "/test.m4a"),
      sampleRate: 1000, startFrame: 1000, endFrame: 4000, text: "Hello world.",
      scope: .sentence, wordIDs: [], sourcePlaybackEndFrame: 4250)
  }

  private func token(_ id: String, _ start: Int?, _ end: Int?, review: Bool = true) -> TranscriptWordToken {
    TranscriptWordToken(id: id, text: id, startFrame: start, endFrame: end, needsTimingReview: review)
  }

  @Test func activeWordStaysThroughItsTrailingPause() {
    let word = token("Hello", 1200, 1800)
    #expect(ProductionWordTiming.previewRange(for: word, in: target) == 1200..<1800)
    #expect(ProductionWordTiming.playingWordID(at: 1500, tokens: [word], in: target) == "Hello")
    #expect(word.needsTimingReview) // Availability must not certify the alignment.
    #expect(ProductionWordTiming.playingWordID(at: 1800, tokens: [word], in: target) == "Hello")
    #expect(ProductionWordTiming.playingWordID(at: 4000, tokens: [word], in: target) == "Hello")
  }

  @Test func missingAndInvalidWordRangesStillUseSentenceContext() {
    for word in [token("missing", nil, nil), token("partial", 1500, nil),
      token("zero", 1500, 1500), token("inverted", 1600, 1500),
      token("negative", -1, 1200), token("before", 900, 1500), token("after", 3500, 4100)] {
      #expect(ProductionWordTiming.range(for: word, in: target) == nil)
      #expect(ProductionWordTiming.previewRange(for: word, in: target) == 1000..<4250)
      #expect(ProductionWordTiming.playingWordID(at: 1500, tokens: [word], in: target) == nil)
    }
  }

  @Test func onlyTheNextPronounceableWordReplacesTheActiveWord() {
    let words = [token("Hello", 1200, 2000), token("world", 1800, 2500), token(".", 2500, 2600)]
    #expect(ProductionWordTiming.playingWordID(at: 1500, tokens: words, in: target) == "Hello")
    #expect(ProductionWordTiming.playingWordID(at: 1900, tokens: words, in: target) == "world")
    #expect(ProductionWordTiming.playingWordID(at: 2100, tokens: words, in: target) == "world")
    #expect(ProductionWordTiming.playingWordID(at: 2550, tokens: words, in: target) == "world")
    #expect(ProductionWordTiming.playingWordID(at: 3000, tokens: words, in: target) == "world")
    let ambiguous = [token("one", 1200, 1600), token("two", 1200, 1700)]
    #expect(ProductionWordTiming.playingWordID(at: 1500, tokens: ambiguous, in: target) == nil)
  }
}
