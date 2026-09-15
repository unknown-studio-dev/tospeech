import SwiftUI

#if DEBUG
struct PracticeTracePreview {
  var reference: DeliveryTrack?
  var live: DeliveryTrack?
  var duration: Double
}

extension EnvironmentValues {
  @Entry var practiceTracePreview: PracticeTracePreview? = nil
  @Entry var practiceWaveformFrame: ((CGRect) -> Void)? = nil
}
#endif

/// Sample both tracks on the original sentence clock. A partial take must never
/// stretch to fill the sentence, and unrecorded columns must remain empty.
struct PracticeWaveformPlot {
  let track: DeliveryTrack
  let duration: Double

  func amplitude(at fraction: Double, through cutoff: Double) -> Double? {
    guard duration.isFinite, duration > 0, fraction.isFinite,
      (0...1).contains(fraction), cutoff.isFinite else { return nil }
    let time = fraction * duration
    guard time <= cutoff, !track.frames.isEmpty else { return nil }
    var low = 0, high = track.frames.count
    while low < high {
      let middle = (low + high) / 2
      if track.frames[middle].time < time { low = middle + 1 } else { high = middle }
    }
    let candidates = [low - 1, low].filter { track.frames.indices.contains($0) }
    guard let index = candidates.min(by: {
      abs(track.frames[$0].time - time) < abs(track.frames[$1].time - time)
    }) else { return nil }
    let frame = track.frames[index]
    guard frame.time.isFinite, frame.relativeDB.isFinite,
      frame.time <= cutoff, abs(frame.time - time) <= 0.04 else { return nil }
    return min(1, max(0, (frame.relativeDB + 40) / 40))
  }
}

struct PracticeWaveformView: View {
  let reference: DeliveryTrack?
  let live: DeliveryTrack?
  let elapsed: Double
  let sentenceDuration: Double?
  #if DEBUG
  @Environment(\.practiceWaveformFrame) private var reportFrame
  #endif

  private var duration: Double {
    // Source duration is fixed throughout capture, even if the recorder's final
    // callback arrives slightly beyond the end of its fixed window.
    if let sentenceDuration, sentenceDuration.isFinite, sentenceDuration > 0 { return sentenceDuration }
    return max(0.001, reference?.duration ?? 0)
  }

  var body: some View {
    GeometryReader { geometry in
      let columns = TimingWaveformBarLayout(width: geometry.size.width)
      ZStack {
        if let reference {
          bars(reference, through: duration, color: EchoTheme.accent.opacity(0.72))
        }
        if let live {
          bars(live, through: min(elapsed, duration), color: EchoTheme.focus.opacity(0.48))
        }
        if elapsed > 0 {
          Path { path in
            let x = columns.x(at: min(1, max(0, elapsed / duration)))
            path.move(to: .init(x: x, y: 0))
            path.addLine(to: .init(x: x, y: geometry.size.height))
          }.stroke(EchoTheme.text.opacity(0.65), lineWidth: 1)
        }
        if reference == nil && live == nil {
          EchoLocalizedText("practice.trace.waiting")
            .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.secondaryText)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .clipped()
    .accessibilityElement(children: .ignore)
    .echoAccessibilityLabel("practice.trace.axis")
    .accessibilityValue(Text(EchoFormat.decimal(elapsed) + " / " + EchoFormat.decimal(duration)))
    #if DEBUG
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { reportFrame?($0) }
    #endif
  }

  private func bars(_ track: DeliveryTrack, through cutoff: Double, color: Color) -> some View {
    let plot = PracticeWaveformPlot(track: track, duration: duration)
    return TimingWaveformBars { index, count, size in
      let fraction = Double(index) / Double(max(1, count - 1))
      return plot.amplitude(at: fraction, through: cutoff).map {
        2 + CGFloat($0) * max(0, size.height - 4)
      }
    } color: { _ in color }
  }
}
