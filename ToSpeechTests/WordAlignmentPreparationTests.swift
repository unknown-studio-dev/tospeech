import Foundation
import Testing
@testable import ToSpeech

struct WordAlignmentPreparationTests {
  private let provenance = TranscriptionProvenance(engine: "CTC", model: "fixture", localeIdentifier: "en", runtimeVersion: "1")
  private var tokens: [TranscriptWordToken] {
    [.init(id: "a", text: "Hello", startFrame: 100, endFrame: 300, needsTimingReview: true),
      .init(id: "b", text: "world", startFrame: 400, endFrame: 800, needsTimingReview: false)]
  }

  @Test func preservesTextIDsAndReviewWhileReplacingSupportedRanges() {
    let output = AlignedTranscriptPreparation.apply([
      .init(text: "Hello", start: 0.15, end: 0.4), nil], to: tokens, sampleRate: 1000, lowerBound: 0, upperBound: 1000)
    #expect(output.tokens[0].id == "a" && output.tokens[0].text == "Hello")
    #expect(output.tokens[0].startFrame == 150 && output.tokens[0].endFrame == 400)
    #expect(output.tokens[0].needsTimingReview)
    #expect(output.tokens[1].startFrame == 400 && output.tokens[1].needsTimingReview)
    #expect(output.accepted == ["a"])
  }

  @Test func partialAlignmentCannotIntroduceOverlapsWithFallbackWords() {
    let output = AlignedTranscriptPreparation.apply([
      .init(text: "Hello", start: 0.15, end: 0.5), nil], to: tokens, sampleRate: 1000, lowerBound: 0, upperBound: 1000)
    #expect(output.accepted.isEmpty)
    #expect(output.tokens[0].endFrame == 300)
    #expect(output.tokens.allSatisfy { $0.needsTimingReview })
  }

  @Test func wrongTextInvalidOrOutOfContextCannotReplaceTiming() {
    for word in [TimedWord(text: "wrong", start: 0.1, end: 0.2),
      TimedWord(text: "Hello", start: .nan, end: 0.2),
      TimedWord(text: "Hello", start: -0.1, end: 0.2),
      TimedWord(text: "Hello", start: 0.2, end: 4)] {
      let output = AlignedTranscriptPreparation.apply([word, nil], to: tokens, sampleRate: 1000, lowerBound: 0, upperBound: 1000)
      #expect(output.tokens[0] == tokens[0])
      #expect(output.accepted.isEmpty)
    }
  }

  @Test func expandsSentenceToContainObservedBoundaryWithoutShrinkingContext() {
    let bounds = AlignedTranscriptPreparation.expandedBounds([
      .init(text: "Hello", start: 0.05, end: 0.85)], start: 100, end: 800, sampleRate: 1000)
    #expect(bounds == 50..<850)
  }

  actor Stub: WordAlignmentAdapter {
    var calls = 0
    func align(_ request: WordAlignmentRequest) async throws -> WordAlignmentResult {
      calls += 1
      return .init(words: request.words.map { Optional($0) }, provenance: .init(engine: "fixture", model: "fixture", localeIdentifier: "en", runtimeVersion: "1"))
    }
  }

  @Test func cacheKeysAudioTranscriptAndPolicyIndependently() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio")
    try Data([1,2,3]).write(to: audio)
    let stub = Stub()
    let cache = CachedWordAligner(underlying: stub, directory: root, version: "one")
    let request = WordAlignmentRequest(audioURL: audio, words: [.init(text: "hello", start: 0, end: 1)])
    _ = try await cache.align(request)
    _ = try await cache.align(request)
    #expect(await stub.calls == 1)
    try Data([1,2,4]).write(to: audio)
    _ = try await cache.align(request)
    _ = try await cache.align(.init(audioURL: audio, words: [.init(text: "world", start: 0, end: 1)]))
    _ = try await CachedWordAligner(underlying: stub, directory: root, version: "two").align(request)
    #expect(await stub.calls == 4)
    var withSentenceStarts = request
    withSentenceStarts.sentenceStartIndices = [0]
    _ = try await cache.align(withSentenceStarts)
    #expect(await stub.calls == 5)
  }
}
