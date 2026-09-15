import Testing
@testable import ToSpeech

struct CTCSentenceOnsetTests {
  @Test func pauseBeforeThisDoesNotRejectItsCorrectedEnd() {
    // Actual failing trace: the previous separator was 960 ms before ASR onset.
    let begin = CTCSentenceOnset.start(observedStart: 24.24, firstEmission: 24.56,
      precedingBoundary: 23.28, chunkStart: 20)
    #expect(abs(begin - 24.24) < 0.0001)
    #expect(abs(begin - 24.24) <= 0.75)
    let updated = AlignedTranscriptPreparation.apply([.init(text: "This", start: begin, end: 24.75)],
      to: [.init(id: "this", text: "This", startFrame: 24240, endFrame: 24560, needsTimingReview: true)],
      sampleRate: 1000, lowerBound: 24240, upperBound: 25000)
    #expect(updated.accepted == ["this"])
    #expect(updated.tokens.first?.endFrame == 24750)
  }

  @Test func ifAfterPauseRetainsOnsetInsteadOfPreviousSentenceEnd() {
    #expect(CTCSentenceOnset.start(observedStart: 41.84, firstEmission: 42.22,
      precedingBoundary: 41.04, chunkStart: 30) == 41.84)
  }

  @Test func preservesContinuousBoundaryAndEarlierFirstWordContext() {
    #expect(CTCSentenceOnset.start(observedStart: 1.44, firstEmission: 1.58,
      precedingBoundary: 1.52, chunkStart: 0) == 1.52)
    #expect(CTCSentenceOnset.start(observedStart: 0.16, firstEmission: 0.3,
      precedingBoundary: nil, chunkStart: 0) == 0.16)
    #expect(CTCSentenceOnset.start(observedStart: 0, firstEmission: 0.02,
      precedingBoundary: nil, chunkStart: 0) == 0)
  }

  @Test func cannotCrossPreviousBoundaryOrDecodedContext() {
    #expect(CTCSentenceOnset.start(observedStart: 10, firstEmission: 12,
      precedingBoundary: 11, chunkStart: 10.5) == 11)
  }
}
