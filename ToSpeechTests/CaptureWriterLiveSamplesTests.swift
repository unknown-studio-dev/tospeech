import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite("Capture writer live samples")
struct CaptureWriterLiveSamplesTests {
  /// Builds a multi-channel buffer from explicit per-channel sample arrays so
  /// tests can give each channel distinct values (a same-signal buffer would
  /// hide a "copy channel 0" bug behind a correct-looking average).
  private func buffer(rate: Double, channels: [[Float]]) -> AVAudioPCMBuffer {
    let frames = channels[0].count
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    for (ch, values) in channels.enumerated() {
      let p = buf.floatChannelData![ch]
      for i in 0..<frames { p[i] = values[i] }
    }
    return buf
  }

  @Test("Stereo buffer is downmixed to the channel average, not a channel copy")
  func averagesChannelsNotJustCopies() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    let writer = CaptureWriter(file: file, url: url, thresholdDB: -42,
      nativeSampleRate: 48_000, channelCount: 2)
    let frames = 4_800
    let ch0 = (0..<frames).map { Float(sin(2 * .pi * 200 * Double($0) / 48_000)) * 0.5 }
    let ch1 = ch0.map { -$0 }
    writer.consume(buffer(rate: 48_000, channels: [ch0, ch1]))
    let snap = writer.liveMonoSnapshot()
    #expect(snap.sampleRate == 48_000)
    #expect(snap.samples.count == frames)
    // If consume copied a channel instead of averaging, this would be ch0's
    // sine wave rather than the true average of ch0 and its negation.
    #expect(snap.samples.allSatisfy { $0 == 0 })
  }

  @Test("Live snapshot trims down to the cap, keeping the most recent samples in order")
  func trimsToCapKeepingMostRecentInOrder() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    // A small labeled native rate keeps the ~35s cap (and its trim slack)
    // cheap to exercise; consume() never reads the buffer's own sample rate.
    let nativeSampleRate = 100.0
    let writer = CaptureWriter(file: file, url: url, thresholdDB: -42,
      nativeSampleRate: nativeSampleRate, channelCount: 1)
    let cap = Int(nativeSampleRate * 35)
    let slack = Int(nativeSampleRate * 5)
    let totalToFeed = cap + slack + 200 // push past the trim threshold
    var fed = 0
    var counter: Float = 0
    let chunk = 500
    while fed < totalToFeed {
      let n = min(chunk, totalToFeed - fed)
      let ramp = (0..<n).map { counter + Float($0) }
      writer.consume(buffer(rate: 48_000, channels: [ramp]))
      counter += Float(n)
      fed += n
    }
    let snap = writer.liveMonoSnapshot()
    #expect(snap.samples.count == cap)
    #expect(snap.samples.first == Float(totalToFeed - cap))
    #expect(snap.samples.last == Float(totalToFeed - 1))
  }
}
