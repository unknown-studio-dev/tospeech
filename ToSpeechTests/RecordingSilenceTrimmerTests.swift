import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite struct RecordingSilenceTrimmerTests {
  // Quiet speech-shaped bursts; weak edges and a 400 ms internal pause.
  static func fixture(to url: URL, rate: Int = 48_000, channels: UInt32 = 1) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate * 4)))
    buffer.frameLength = UInt32(rate * 4)
    for ch in 0..<Int(channels) {
      for i in 0..<rate * 4 {
        let t = Double(i)/Double(rate)
        let level = (1..<1.1).contains(t) || (2.3..<2.4).contains(t) ? 0.004
          : ((1.1..<1.6).contains(t) || (2..<2.3).contains(t) ? 0.03 : 0)
        buffer.floatChannelData![ch][i] = ch == 0 ? Float(level * sin(2 * .pi * 200 * t)) : 0
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  private func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  @Test(arguments: [48_000, 44_100])
  func trimsOnlyEdgesPreservingWeakSoundsInternalPauseAndExactPCM(rate: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("trim-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original.caf"), output = root.appendingPathComponent("trimmed.caf")
    try Self.fixture(to: original, rate: rate, channels: 2)
    let originalHash = try RecordingSilenceTrimmer.checksum(original)
    let plan = try RecordingSilenceTrimmer.plan(url: original)
    #expect(abs(Double(plan.startFrame)/Double(rate) - 0.92) < 0.011)
    #expect(abs(Double(plan.endFrame)/Double(rate) - 2.52) < 0.011)
    try RecordingSilenceTrimmer.write(source: original, destination: output, plan: plan)
    #expect(try samples(output) == Array(samples(original)[plan.startFrame..<plan.endFrame]))
    #expect(try RecordingSilenceTrimmer.checksum(original) == originalHash)
    let written = try AVAudioFile(forReading: output)
    #expect(written.length == plan.frameCount && written.processingFormat.channelCount == 2)
  }

  @Test func silenceFlatNoiseAndSingleClickNeverBecomeEmptyTakes() {
    let full = RecordingTrimPlan(originalFrames: 48_000, sampleRate: 48_000, startFrame: 0, endFrame: 48_000)
    var click = Array(repeating: -120.0, count: 100); click[50] = -10
    for values in [Array(repeating: -120.0, count: 100), Array(repeating: -42.0, count: 100), click] {
      #expect(RecordingSilenceTrimmer.bounds(levels: values, full: full, hop: 480) == full)
    }
    let voiced = Array(repeating: -25.0, count: 100)
    #expect(RecordingSilenceTrimmer.bounds(levels: voiced, full: full, hop: 480) == full)
  }
}
