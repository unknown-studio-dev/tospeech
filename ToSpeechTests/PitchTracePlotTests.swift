import CoreGraphics
import Foundation
import Testing
@testable import ToSpeech

@Suite("Practice waveform overlay alignment")
struct PitchTracePlotTests {
  private func track(until end: Double) -> DeliveryTrack {
    let frames = stride(from: 0.0, through: end, by: 0.02).map {
      DeliveryFrame(time: $0, relativeDB: $0 < 0.5 ? -20 : -5, pitchSemitones: nil)
    }
    return DeliveryTrack(duration: end, frames: frames, pauses: [], activeSpan: nil)
  }

  @Test("A partial recording uses the original clock without stretching")
  func partialCaptureUsesSourceClock() {
    let source = PracticeWaveformPlot(track: track(until: 2), duration: 2)
    let recording = PracticeWaveformPlot(track: track(until: 1), duration: 2)
    for fraction in stride(from: 0.0, through: 0.5, by: 0.01) {
      #expect(source.amplitude(at: fraction, through: 2) == recording.amplitude(at: fraction, through: 1))
    }
    #expect(recording.amplitude(at: 0.75, through: 1) == nil)
  }

  @Test("Live overlay leaves every future column empty")
  func noFutureBars() {
    let plot = PracticeWaveformPlot(track: track(until: 2), duration: 2)
    #expect(plot.amplitude(at: 0.25, through: 0.5) != nil)
    #expect(plot.amplitude(at: 0.26, through: 0.5) == nil)
    #expect(plot.amplitude(at: 1, through: 0.5) == nil)
  }

  @Test("Shared capsule columns and seeking have the same time coordinates")
  func columnAlignment() {
    for width in [704.0, 984, 1504] {
      let columns = TimingWaveformBarLayout(width: width)
      for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
        #expect(abs(columns.fraction(at: columns.x(at: fraction)) - fraction) < 0.0001)
      }
      #expect(columns.start >= 10)
      #expect(columns.x(at: 1) <= width - 10)
    }
  }

  @Test("Missing or nonfinite signal is not drawn as speech")
  func missingSignal() {
    let sparse = DeliveryTrack(duration: 2, frames: [
      .init(time: 0, relativeDB: .nan, pitchSemitones: nil),
      .init(time: 1, relativeDB: -20, pitchSemitones: nil),
    ], pauses: [], activeSpan: nil)
    let plot = PracticeWaveformPlot(track: sparse, duration: 2)
    #expect(plot.amplitude(at: 0, through: 2) == nil)
    #expect(plot.amplitude(at: 0.25, through: 2) == nil)
    #expect(plot.amplitude(at: 0.5, through: 2) == 0.5)
  }
}
