import SwiftUI

enum TraceDimension: String, CaseIterable, Identifiable {
  case pitch, energy, both
  var id: String { rawValue }
  var title: String { "practice.trace.\(rawValue)" }   // localized keys
}

/// Pure geometry for the trace. Mirrors DeliveryContour's proven mapping
/// (±12 semitone axis, (db+40)/40 energy, 0.06s gap break) so the bar view
/// stays independent of the review view yet visually consistent.
struct PitchTracePlot {
  let track: DeliveryTrack
  let duration: Double
  let size: CGSize

  private func x(_ time: Double) -> CGFloat? {
    guard let f = ReviewSignalScale.fraction(time: time, duration: duration) else { return nil }
    return CGFloat(f) * size.width
  }

  func pitchSegments() -> [[CGPoint]] {
    var segments: [[CGPoint]] = []
    var current: [CGPoint] = []
    var previousTime: Double?
    for frame in track.frames {
      guard let semi = frame.pitchSemitones, semi.isFinite, let px = x(frame.time) else {
        if !current.isEmpty { segments.append(current); current = [] }
        previousTime = nil; continue
      }
      if let previousTime, frame.time - previousTime > 0.06, !current.isEmpty {
        segments.append(current); current = []
      }
      let normalized = min(1, max(0, (semi + 12) / 24))
      current.append(CGPoint(x: px, y: (1 - normalized) * size.height))
      previousTime = frame.time
    }
    if !current.isEmpty { segments.append(current) }
    return segments
  }

  /// Symmetric envelope points (top half) from relativeDB; view mirrors them.
  func energyEnvelope() -> [CGPoint] {
    track.frames.compactMap { frame in
      guard let px = x(frame.time) else { return nil }
      let amp = min(1, max(0, (frame.relativeDB + 40) / 40))
      return CGPoint(x: px, y: CGFloat(amp))   // y = amplitude 0…1 (view scales)
    }
  }
}

struct LivePitchEnergyTrace: View {
  let reference: DeliveryTrack?
  let live: DeliveryTrack?
  let elapsed: Double
  let sentenceDuration: Double?
  @State private var dimension: TraceDimension = .both

  private var duration: Double {
    ReviewSignalScale.duration([sentenceDuration ?? 0, reference?.duration ?? 0, live?.duration ?? 0])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoSegmented(selection: $dimension,
        options: TraceDimension.allCases.map { ($0, $0.title) }, labelSize: 11, horizontalPadding: 6)
        .fixedSize(horizontal: true, vertical: false)
      Canvas { context, size in
        let showEnergy = dimension != .pitch
        let showPitch = dimension != .energy
        if let reference { paint(reference, in: &context, size: size, upTo: duration,
          dim: true, showEnergy: showEnergy, showPitch: showPitch) }
        if let live { paint(live, in: &context, size: size, upTo: elapsed,
          dim: false, showEnergy: showEnergy, showPitch: showPitch) }
        // playhead
        if let f = ReviewSignalScale.fraction(time: elapsed, duration: duration) {
          var cursor = Path()
          cursor.move(to: .init(x: CGFloat(f) * size.width, y: 0))
          cursor.addLine(to: .init(x: CGFloat(f) * size.width, y: size.height))
          context.stroke(cursor, with: .color(EchoTheme.text.opacity(0.9)), lineWidth: 1.5)
        }
      }
      .frame(maxWidth: .infinity)
      .echoAccessibilityLabel("practice.trace.axis")
    }
    .background(EchoTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
  }

  private func paint(_ track: DeliveryTrack, in context: inout GraphicsContext, size: CGSize,
    upTo: Double, dim: Bool, showEnergy: Bool, showPitch: Bool) {
    let plot = PitchTracePlot(track: track, duration: duration, size: size)
    if showEnergy {
      let env = plot.energyEnvelope().filter { p in p.x <= (CGFloat((ReviewSignalScale.fraction(time: upTo, duration: duration) ?? 1)) * size.width) + 0.5 }
      if env.count > 1 {
        var path = Path()
        let mid = size.height / 2, amp = size.height / 2 * 0.9
        path.move(to: .init(x: env[0].x, y: mid - env[0].y * amp))
        for p in env.dropFirst() { path.addLine(to: .init(x: p.x, y: mid - p.y * amp)) }
        for p in env.reversed() { path.addLine(to: .init(x: p.x, y: mid + p.y * amp)) }
        path.closeSubpath()
        context.fill(path, with: .color((dim ? EchoTheme.secondaryText : EchoTheme.focus).opacity(dim ? 0.22 : 0.4)))
      }
    }
    if showPitch {
      for seg in plot.pitchSegments() where seg.count > 1 {
        guard seg.allSatisfy({ $0.x <= (CGFloat((ReviewSignalScale.fraction(time: upTo, duration: duration) ?? 1)) * size.width) + 0.5 }) else { continue }
        var path = Path(); path.move(to: seg[0])
        for p in seg.dropFirst() { path.addLine(to: p) }
        context.stroke(path, with: .color(dim ? EchoTheme.secondaryText.opacity(0.5) : EchoTheme.accent),
          style: .init(lineWidth: dim ? 2 : 2.5, lineCap: .round, dash: dim ? [5, 4] : []))
      }
    }
  }
}
