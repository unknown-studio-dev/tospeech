import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite struct ReviewSignalTests {
  private func file(rate: Int = 44_100, seconds: Double = 2, signal: (Int) -> Float) throws -> ReviewAudioAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("signal-\(UUID()).caf")
    let frames = Int((Double(rate) * seconds).rounded())
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
      buffer.floatChannelData![0][frame] = 0
      buffer.floatChannelData![1][frame] = signal(frame)
    }
    let audio = try AVAudioFile(forWriting: url, settings: format.settings)
    try audio.write(from: buffer)
    return .init(id: UUID().uuidString, url: url, sampleRate: rate, startFrame: 0, endFrame: frames)
  }

  @Test func waveformReadsOnlySavedSourceRangeAndAllChannels() async throws {
    let whole = try file { $0 < 22_050 ? 0.9 : $0 < 44_100 ? 0.2 : 0.4 }
    defer { try? FileManager.default.removeItem(at: whole.url) }
    let part = ReviewAudioAsset(id: "source", url: whole.url, sampleRate: 44_100, startFrame: 22_050, endFrame: 66_150)
    let wave = try await ReviewSignalAnalyzer().waveform(part)
    #expect(wave.duration == 1)
    #expect(abs(wave.peaks.first! - 0.2) < 0.001)
    #expect(abs(wave.peaks.last! - 0.4) < 0.001)
    #expect(wave.peaks.max()! < 0.401)
  }

  @Test func independentClocksDoNotStretchOrPlayBeyondShorterTrack() {
    let asset = ReviewAudioAsset(id: "source", url: URL(fileURLWithPath: "/unused"),
      sampleRate: 48_000, startFrame: 480_000, endFrame: 576_000)
    let scale = ReviewSignalScale.duration([2, 4, .nan, .infinity])
    #expect(scale == 4)
    #expect(ReviewSignalScale.playbackStart(fraction: 0.25, scale: scale, asset: asset) == 11)
    #expect(ReviewSignalScale.playbackStart(fraction: 0.75, scale: scale, asset: asset) == nil)
    #expect(ReviewSignalScale.playbackStart(fraction: .nan, scale: scale, asset: asset) == nil)
    #expect(ReviewSignalScale.fraction(time: 1, duration: 4) == 0.25)
    #expect(ReviewSignalScale.fraction(time: 1, duration: .nan) == nil)
  }

  @Test func silenceHasNoInventedPeaksOrPitch() async throws {
    let asset = try file(rate: 16_000, seconds: 0.5) { _ in 0 }
    defer { try? FileManager.default.removeItem(at: asset.url) }
    let analyzer = ReviewSignalAnalyzer()
    let wave = try await analyzer.waveform(asset)
    let track = try await analyzer.contour(asset)
    #expect(wave.peaks.allSatisfy { $0 == 0 })
    #expect(track.pitchFrames == 0)
    #expect(track.activeSpan == nil)
    #expect(track.duration == 0.5)
  }

  @Test func wrongRateAndOutOfBoundsAreErrors() async throws {
    let asset = try file { _ in 0 }
    defer { try? FileManager.default.removeItem(at: asset.url) }
    let analyzer = ReviewSignalAnalyzer()
    for invalid in [
      ReviewAudioAsset(id: "bad-rate", url: asset.url, sampleRate: 48_000, startFrame: 0, endFrame: 1000),
      ReviewAudioAsset(id: "bad-range", url: asset.url, sampleRate: asset.sampleRate, startFrame: 0, endFrame: asset.endFrame+1)
    ] {
      await #expect(throws: ProductionPracticeError.invalidPlaybackRange) { try await analyzer.waveform(invalid) }
    }
  }

  @Test func cacheSeparatesDifferentRangesOfSameFile() async throws {
    let asset = try file { $0 < 44_100 ? 0.1 : 0.8 }
    defer { try? FileManager.default.removeItem(at: asset.url) }
    let analyzer = ReviewSignalAnalyzer()
    let a = ReviewAudioAsset(id: "source", url: asset.url, sampleRate: 44_100, startFrame: 0, endFrame: 44_100)
    let b = ReviewAudioAsset(id: "source", url: asset.url, sampleRate: 44_100, startFrame: 44_100, endFrame: 88_200)
    let first = try await analyzer.waveform(a), second = try await analyzer.waveform(b)
    #expect(first.peaks.max()! < 0.11)
    #expect(second.peaks.min()! > 0.79)
  }
}
