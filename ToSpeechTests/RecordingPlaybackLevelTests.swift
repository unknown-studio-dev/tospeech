import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite struct RecordingPlaybackLevelTests {
  private func signal(amplitude: Float, channels: UInt32 = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID()).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<Int(channels) {
      for frame in 0..<48_000 {
        buffer.floatChannelData![channel][frame] = channel == 0
          ? amplitude * Float(sin(2 * .pi * 200 * Double(frame) / 48_000)) : 0
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  @Test func quietTakeGetsConstantGainWithoutChangingOriginalOrSilentChannelBias() throws {
    let mono = try signal(amplitude: 0.02), stereo = try signal(amplitude: 0.02, channels: 2)
    defer { try? FileManager.default.removeItem(at: mono); try? FileManager.default.removeItem(at: stereo) }
    let before = try Data(contentsOf: mono)
    let gain = try RecordingPlaybackLevel.gain(url: mono)
    #expect(abs(gain - 12.9897) < 0.05)
    #expect(abs(try RecordingPlaybackLevel.gain(url: stereo) - gain) < 0.01)
    #expect(try Data(contentsOf: mono) == before)
  }

  @Test func silenceNoiseFloorAndHotPeaksDoNotGetBoosted() {
    #expect(RecordingPlaybackLevel.gain(blockEnergies: Array(repeating: 0, count: 50), peak: 0) == 0)
    #expect(RecordingPlaybackLevel.gain(blockEnergies: Array(repeating: 1e-7, count: 50), peak: 0.001) == 0)
    #expect(RecordingPlaybackLevel.gain(blockEnergies: Array(repeating: 1e-4, count: 50), peak: 0.9) == 0)
    let capped = RecordingPlaybackLevel.gain(blockEnergies: Array(repeating: 1e-4, count: 50), peak: 0.5)
    #expect(abs(capped - 3.0206) < 0.01)
    #expect(0.5 * pow(10, Double(capped)/20) <= pow(10, -3.0/20) + 1e-6)
    #expect(RecordingPlaybackLevel.gain(blockEnergies: Array(repeating: 1e-5, count: 50), peak: 0.01) == 18)
  }

  @MainActor @Test func gainAppliesToWholeTakeDetailsAndTogetherButNeverLeaksToSource() async throws {
    let url = try signal(amplitude: 0.02)
    defer { try? FileManager.default.removeItem(at: url) }
    let player = ProductionAudioPlayer()
    defer { player.stop() }
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 1, levelRecording: true)
    player.pause()
    for _ in 0..<200 where player.isPreparing { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!player.isPreparing && player.state == .paused)
    let gain = player.recordingGainDB
    #expect(gain > 12)
    try player.play(url: url, startFrame: 12_000, endFrame: 24_000, speed: 1, levelRecording: true)
    #expect(player.recordingGainDB == gain)
    try player.playTogether(sourceURL: url, sourceFrames: 0..<24_000, takeURL: url,
      takeFrames: 0..<48_000, levelRecording: true)
    #expect(player.recordingGainDB == gain && player.isSimultaneous && player.state == .playing)
    try player.play(url: url, startFrame: 0, endFrame: 24_000, speed: 1)
    #expect(player.recordingGainDB == 0 && !player.isSimultaneous)
  }

  @MainActor @Test func stoppingPreparationCannotStartObsoleteRecording() async throws {
    let url = try signal(amplitude: 0.02)
    defer { try? FileManager.default.removeItem(at: url) }
    let player = ProductionAudioPlayer()
    var completions = 0
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 1, levelRecording: true) { completions += 1 }
    player.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(player.state == .idle && !player.isPreparing && player.recordingGainDB == 0 && completions == 0)
  }
}
