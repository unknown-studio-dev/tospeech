import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite struct RecordingEnhancementTests {
  private func fixture(rate: Double = 48_000, channels: UInt32 = 1, frames: Int = 96_017,
    silence: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dfn-test-\(UUID()).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
    buffer.frameLength = UInt32(frames)
    var random: UInt64 = 13
    for channel in 0..<Int(channels) {
      for i in 0..<frames {
        random = random &* 6364136223846793005 &+ 1
        buffer.floatChannelData![channel][i] = silence ? 0 : Float(Double(random >> 32) / Double(UInt32.max) - 0.5) * 0.04
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  private func tailEnergy(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let count = min(4800, Int(file.length))
    file.framePosition = file.length - Int64(count)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count)))
    try file.read(into: buffer)
    return (0..<count).reduce(0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) } / Double(count)
  }

  @Test func bundledModelReducesStationaryNoiseWithoutChangingFramesOrCapture() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)
    let enhanced = try await DeepFilterRecordingRenderer.render(url: url)
    #expect(enhanced.frameCount == 96_017)
    try DeepFilterRecordingRenderer.validate(enhanced.url, frames: 96_017, rate: 48_000, channels: 1)
    #expect(try tailEnergy(enhanced.url) < tailEnergy(url) * 0.3)
    #expect(try Data(contentsOf: url) == original)
  }

  @Test func silenceStaysSilentAndLegacyStereo44100KeepsItsOwnClock() async throws {
    for silent in [true, false] {
      let url = try fixture(rate: 44_100, channels: 2, frames: 88_217, silence: silent)
      defer { try? FileManager.default.removeItem(at: url) }
      let audio = try await DeepFilterRecordingRenderer.prepare(url: url, enhance: true)
      try DeepFilterRecordingRenderer.validate(audio.url, frames: 88_217, rate: 44_100, channels: 2)
      if silent { #expect(audio.gain == 0); #expect(try tailEnergy(audio.url) == 0) }
      else { #expect(try tailEnergy(audio.url) > 0) } // Padded tail is drained, not zeroed.
    }
  }

  @MainActor @Test func enhancedPlaybackSupportsPauseCacheExcerptsTogetherAndRawSwitch() async throws {
    let url = try fixture(silence: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let player = ProductionAudioPlayer()
    defer { player.stop() }
    try player.play(url: url, startFrame: 0, endFrame: 96_017, speed: 1, levelRecording: true, enhanceRecording: true)
    player.pause()
    for _ in 0..<1000 where player.isPreparing { try await Task.sleep(for: .milliseconds(20)) }
    #expect(player.state == .paused && player.isRecordingEnhanced && !player.isPreparing)
    #expect(player.sampleRate == 48_000 && player.assetURL == url)
    try player.seek(to: 12_000)
    #expect(player.sourceFrame == 12_000)
    try player.play(url: url, startFrame: 12_000, endFrame: 24_000, speed: 1, levelRecording: true, enhanceRecording: true)
    #expect(player.isRecordingEnhanced && !player.isPreparing)
    try player.playTogether(sourceURL: url, sourceFrames: 0..<48_000, takeURL: url,
      takeFrames: 0..<96_017, levelRecording: true, enhanceRecording: true)
    #expect(player.isSimultaneous && player.isRecordingEnhanced && !player.isPreparing)
    #expect(abs(player.secondDuration - Double(96_017)/48_000) < 1e-8)
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 1)
    #expect(!player.isRecordingEnhanced && player.recordingGainDB == 0)
  }

  @MainActor @Test func cancelledOrFailedEnhancementNeverFallsBackOrStartsAnObsoleteTake() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let player = ProductionAudioPlayer(prepareRecordingAudio: { _, _ in
      try await Task.sleep(for: .milliseconds(120))
      throw RecordingEnhancementError.processing
    })
    var failures = 0
    player.onFailure = { _ in failures += 1 }
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 1, levelRecording: true, enhanceRecording: true)
    player.stop()
    try await Task.sleep(for: .milliseconds(200))
    #expect(player.state == .idle && failures == 0)
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 1, levelRecording: true, enhanceRecording: true)
    for _ in 0..<100 where player.isPreparing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(player.state == .failed("recording.enhance.failed") && failures == 1)
    #expect(!player.isRecordingEnhanced)
  }

  @Test func preferenceMigratesOldSnapshotsAndMissingHelperIsExplicit() async throws {
    let encoded = try JSONEncoder().encode(Preferences())
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "enhancedRecordingPlayback")
    var decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.enhanceRecordings)
    decoded.enhanceRecordings = false
    #expect(try !JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(decoded)).enhanceRecordings)
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      _ = try await DeepFilterRecordingRenderer.render(url: url, resources: url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
      Issue.record("A missing bundled helper must fail")
    } catch { #expect(error.localizedDescription == "recording.enhance.unavailable") }
  }
}
