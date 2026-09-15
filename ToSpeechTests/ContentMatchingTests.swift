import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

struct ContentMatchingTests {
  @Test func punctuationCaseAndCurlyApostropheDoNotCreateErrors() throws {
    let match = try ContentMatch.compare(expected: "We're HERE, aren't we?", observed: "we’re here aren't we")
    #expect(match.differences.isEmpty)
    #expect(match.hasRecognizedSpeech)
  }

  @Test func missingExtraAndDifferentWordsRemainOrdered() throws {
    let missing = try ContentMatch.compare(expected: "I really like tea", observed: "I like tea")
    #expect(missing.differences == [.init(kind: .missing, expected: "really", observed: nil)])
    let extra = try ContentMatch.compare(expected: "I like tea", observed: "I I like tea")
    #expect(extra.differences == [.init(kind: .extra, expected: nil, observed: "i")])
    let different = try ContentMatch.compare(expected: "I like tea", observed: "I like coffee")
    #expect(different.differences == [.init(kind: .different, expected: "tea", observed: "coffee")])
  }

  @Test func omittedAndRepeatedWordsDoNotBecomeCascadingSubstitutions() throws {
    let match = try ContentMatch.compare(expected: "I never thought it would make such a difference",
      observed: "I thought it would make a difference difference")
    #expect(match.differences.filter { $0.kind == .missing }.map(\.expected) == ["never", "such"])
    #expect(match.differences.filter { $0.kind == .extra }.map(\.observed) == ["difference"])
    #expect(!match.words.contains { $0.kind == .different })
  }

  @Test func reorderedWordsDoNotLookLikeAFullMatch() throws {
    let match = try ContentMatch.compare(expected: "you help me", observed: "me help you")
    #expect(match.differences.count == 2)
  }

  @Test func noRecognizedWordsDoesNotBecomeAnAllWrongGrade() throws {
    let match = try ContentMatch.compare(expected: "Hello there", observed: "... !")
    #expect(!match.hasRecognizedSpeech)
  }

  @Test func excessiveTranscriptIsRejectedBeforeMatrixAllocation() {
    #expect(throws: ContentMatchingError.self) {
      try ContentMatch.compare(expected: "hello", observed: Array(repeating: "word", count: 513).joined(separator: " "))
    }
  }

  @Test func closingCaptureWriterFinalizesPlayableCAFWithoutMicrophone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let writer = try CaptureWriter(file: AVAudioFile(forWriting: url, settings: format.settings), url: url, thresholdDB: -42)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
    buffer.frameLength = 4_000
    for index in 0..<4_000 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.2) * 0.2 }
    writer.consume(buffer)
    let snapshot = writer.finish()
    #expect(snapshot.error == nil)
    #expect(snapshot.voicedFrames == 4_000)
    #expect(try AVAudioFile(forReading: url).length == 4_000)
    writer.consume(buffer)
    #expect(writer.snapshot().frameCount == 4_000)
  }
}
