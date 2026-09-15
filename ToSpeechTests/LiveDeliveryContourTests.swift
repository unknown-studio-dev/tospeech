// ToSpeechTests/LiveDeliveryContourTests.swift
import Foundation
import Testing
@testable import ToSpeech

@Suite("Live delivery contour")
struct LiveDeliveryContourTests {
  /// Mono sine helper at a given rate.
  private func sine(hz: Double, seconds: Double, rate: Double) -> [Float] {
    let n = Int(seconds * rate)
    return (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / rate)) * 0.5 }
  }

  @Test("Steady tone resampled from 48k yields near-zero relative semitones")
  func steadyTone() {
    let samples = sine(hz: 200, seconds: 0.8, rate: 48_000)
    let track = LiveDeliveryContour.track(monoSamples: samples, inputSampleRate: 48_000)
    #expect(track != nil)
    let voiced = track!.frames.compactMap(\.pitchSemitones)
    #expect(voiced.count >= 8)
    // A single steady pitch sits on its own median → ~0 semitones.
    #expect(voiced.allSatisfy { abs($0) < 1.5 })
  }

  @Test("Silence produces no voiced pitch frames")
  func silence() {
    let track = LiveDeliveryContour.track(monoSamples: [Float](repeating: 0, count: 16_000), inputSampleRate: 16_000)
    #expect(track != nil)
    #expect(track!.pitchFrames == 0)
  }

  @Test("Too little audio returns nil")
  func tooShort() {
    #expect(LiveDeliveryContour.track(monoSamples: [Float](repeating: 0.1, count: 100), inputSampleRate: 16_000) == nil)
  }
}
