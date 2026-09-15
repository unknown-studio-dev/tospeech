import CoreGraphics
import Foundation
import Testing
@testable import ToSpeech

@Suite("Pitch trace plot mapping")
struct PitchTracePlotTests {
  private func track(_ frames: [DeliveryFrame], duration: Double) -> DeliveryTrack {
    DeliveryTrack(duration: duration, frames: frames, pauses: [], activeSpan: nil)
  }

  @Test("Semitone axis maps +12 to top, -12 to bottom")
  func pitchAxis() {
    let t = track([
      .init(time: 0, relativeDB: -5, pitchSemitones: 12),
      .init(time: 0.05, relativeDB: -5, pitchSemitones: -12),
    ], duration: 0.05)
    let plot = PitchTracePlot(track: t, duration: 0.05, size: .init(width: 100, height: 80))
    let seg = plot.pitchSegments().first!
    #expect(abs(seg.first!.y - 0) < 0.5)      // +12 → y≈0 (top)
    #expect(abs(seg.last!.y - 80) < 0.5)      // -12 → y≈height (bottom)
    #expect(abs(seg.last!.x - 100) < 0.5)     // time=duration → x=width
  }

  @Test("A gap larger than 0.06s splits the pitch line into segments")
  func gapSplits() {
    let t = track([
      .init(time: 0.0, relativeDB: -5, pitchSemitones: 0),
      .init(time: 0.02, relativeDB: -5, pitchSemitones: 0),
      .init(time: 0.5, relativeDB: -5, pitchSemitones: 0),   // >0.06 gap
    ], duration: 0.5)
    let plot = PitchTracePlot(track: t, duration: 0.5, size: .init(width: 100, height: 80))
    #expect(plot.pitchSegments().count == 2)
  }

  @Test("Unvoiced frames are excluded from pitch segments")
  func unvoiced() {
    let t = track([
      .init(time: 0, relativeDB: -5, pitchSemitones: nil),
      .init(time: 0.02, relativeDB: -5, pitchSemitones: 3),
    ], duration: 0.02)
    let plot = PitchTracePlot(track: t, duration: 0.02, size: .init(width: 100, height: 80))
    #expect(plot.pitchSegments().flatMap { $0 }.count == 1)
  }

  @Test("Energy envelope maps -40dB to 0 and 0dB to 1")
  func energyEnvelope() {
    let t = track([
      .init(time: 0, relativeDB: -40, pitchSemitones: nil),
      .init(time: 0.05, relativeDB: 0, pitchSemitones: nil),
    ], duration: 0.05)
    let plot = PitchTracePlot(track: t, duration: 0.05, size: .init(width: 100, height: 80))
    let env = plot.energyEnvelope()
    #expect(abs(env.first!.y - 0) < 0.01)     // -40dB → amplitude≈0
    #expect(abs(env.last!.y - 1) < 0.01)      // 0dB → amplitude≈1
  }
}
