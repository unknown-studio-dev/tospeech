import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

struct AudioTapIsolationTests {
  nonisolated private static func assertBackgroundThread() {
    #expect(!Thread.isMainThread)
  }

  /// The old tests called CaptureWriter.consume directly and missed the closure's
  /// inherited MainActor check. Invoke the very callback installed on the engine.
  @MainActor @Test func audioTapCreatedByUIAcceptsBackgroundBuffersAndFinalizes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-isolation-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let writer = try CaptureWriter(file: AVAudioFile(forWriting: url, settings: format.settings),
      url: url, thresholdDB: -42)
    let tap = writer.makeAudioTap()
    try await Task.detached {
      Self.assertBackgroundThread()
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
      buffer.frameLength = 1_024
      let channel = try #require(buffer.floatChannelData?[0])
      for index in 0..<1_024 { channel[index] = sin(Float(index) * 0.2) * 0.2 }
      for index in 0..<4 {
        tap(buffer, AVAudioTime(sampleTime: Int64(index * 1_024), atRate: 16_000))
      }
    }.value
    let snapshot = writer.finish()
    #expect(snapshot.error == nil)
    #expect(snapshot.frameCount == 4_096)
    #expect(snapshot.voicedFrames == 4_096)
    #expect(snapshot.peakDB > -42)
    #expect(try AVAudioFile(forReading: url).length == 4_096)
  }

  @MainActor @Test func audioTapArrivingAfterFinishDoesNotWriteIntoClosedTake() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-finished-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let writer = try CaptureWriter(file: AVAudioFile(forWriting: url, settings: format.settings),
      url: url, thresholdDB: -42)
    let tap = writer.makeAudioTap()
    _ = writer.finish()
    try await Task.detached {
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
      buffer.frameLength = 1_024
      tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
    }.value
    #expect(writer.snapshot().frameCount == 0)
    #expect(writer.snapshot().error == nil)
  }
}
