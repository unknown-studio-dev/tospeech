import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite("Capture writer live samples")
struct CaptureWriterLiveSamplesTests {
  private func buffer(rate: Double, channels: AVAudioChannelCount, frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<Int(channels) {
      let p = buf.floatChannelData![ch]
      for i in 0..<frames { p[i] = Float(sin(2 * .pi * 200 * Double(i) / rate)) * 0.5 }
    }
    return buf
  }

  @Test("Stereo buffer is downmixed and accumulated at native rate")
  func accumulates() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    let writer = CaptureWriter(file: file, url: url, thresholdDB: -42,
      nativeSampleRate: 48_000, channelCount: 2)
    writer.consume(buffer(rate: 48_000, channels: 2, frames: 4_800))
    let snap = writer.liveMonoSnapshot()
    #expect(snap.sampleRate == 48_000)
    #expect(snap.samples.count == 4_800)
  }
}
