import SwiftUI

struct TimingWaveform: View {
  let span: AudioSpan
  let viewport: AudioSpan
  let limits: AudioSpan
  let selectedHandle: TimingHandle
  var samples: [Double]? = nil
  var sampleDomain: AudioSpan? = nil
  var usesSimulatedSamples = true
  var loading = false
  var loadError: String? = nil
  var onRetry: (() -> Void)? = nil
  let update: (AudioSpan) -> Void

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let range = max(viewport.duration, TimingRules.minimumSpan)
      let startX = CGFloat((span.start - viewport.start) / range) * width
      let endX = CGFloat((span.end - viewport.start) / range) * width
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 12).fill(EchoTheme.canvas)
        if samples?.isEmpty == false || usesSimulatedSamples {
          TimingWaveformBars { index, _, size in
            barHeight(index: index, width: size.width, height: size.height)
          } color: { position in
            position >= startX && position <= endX
              ? EchoTheme.accent : EchoTheme.text.opacity(0.28)
          }
        } else if let loadError {
          HStack(spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
              .foregroundStyle(EchoTheme.caution)
            EchoLocalizedText("timing.waveform.failed").font(EchoFont.body(size: 11))
              .foregroundStyle(EchoTheme.secondaryText)
              .lineLimit(2)
              .help(Text(verbatim: loadError))
            Spacer()
            if let onRetry { EchoButton("Retry", symbol: "arrow.clockwise", action: onRetry) }
          }.padding(.horizontal, 14).background(EchoTheme.canvas).zIndex(1)
        } else {
          HStack(spacing: 8) {
            if loading { EchoSpinner() }
            EchoLocalizedText("Preparing waveform from local audio…")
              .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.secondaryText)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        handle(
          at: startX, isStart: true, width: width, range: range, height: proxy.size.height - 14)
        handle(at: endX, isStart: false, width: width, range: range, height: proxy.size.height - 14)
      }.coordinateSpace(name: "timing-waveform")
    }
    .accessibilityElement(children: .contain)
    .focusable().focusEffectDisabled()
    .onKeyPress(.leftArrow) {
      keyboardNudge(-0.01)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      keyboardNudge(0.01)
      return .handled
    }
  }

  private func barHeight(index: Int, width: CGFloat, height: CGFloat) -> CGFloat {
    let maximum = max(10, height - 18)
    guard let samples, !samples.isEmpty, let domain = sampleDomain, domain.duration > 0 else {
      if !usesSimulatedSamples { return 8 }
      return min(maximum, 10 + CGFloat((index * 17) % 46))
    }
    let barCount = max(1, Int((width - 20) / 8))
    let fraction = Double(index) / Double(max(1, barCount - 1))
    let time = viewport.start + fraction * viewport.duration
    let sampleFraction = (time - domain.start) / domain.duration
    let sampleIndex = min(samples.count - 1, max(0, Int(sampleFraction * Double(samples.count - 1))))
    return 8 + CGFloat(max(0, min(1, samples[sampleIndex]))) * (maximum - 8)
  }

  private func handle(at x: CGFloat, isStart: Bool, width: CGFloat, range: Double, height: CGFloat)
    -> some View
  {
    RoundedRectangle(cornerRadius: 2).fill(EchoTheme.text).frame(width: 3, height: max(20, height))
      .padding(.horizontal, 8).contentShape(Rectangle()).offset(x: x - 9.5)
      .gesture(
        DragGesture(coordinateSpace: .named("timing-waveform")).onChanged { gesture in
          let seconds = Double(gesture.location.x / width) * range + viewport.start
          var next = span
          if selectedHandle == .move {
            let anchor = isStart ? span.start : span.end
            let delta = seconds - anchor
            next = AudioSpan(start: span.start + delta, end: span.end + delta)
          } else if isStart {
            next.start = seconds
          } else {
            next.end = seconds
          }
          if isAllowed(next) { update(next) }
        }
      )
      .echoAccessibilityLabel(isStart ? "Start timing handle" : "End timing handle")
      .accessibilityValue(EchoFormat.time(isStart ? span.start : span.end))
      .accessibilityAdjustableAction { direction in
        let delta = direction == .increment ? 0.01 : -0.01
        var next = span
        if selectedHandle == .move {
          next = AudioSpan(start: next.start + delta, end: next.end + delta)
        } else if isStart {
          next.start += delta
        } else {
          next.end += delta
        }
        if isAllowed(next) { update(next) }
      }
  }

  private func keyboardNudge(_ delta: Double) {
    var next = span
    switch selectedHandle {
    case .start: next.start += delta
    case .end: next.end += delta
    case .move: next = AudioSpan(start: next.start + delta, end: next.end + delta)
    }
    if isAllowed(next) { update(next) }
  }

  private func isAllowed(_ span: AudioSpan) -> Bool {
    span.start >= limits.start && span.end <= limits.end && span.duration > TimingRules.minimumSpan
  }
}

/// Shared centered capsule bars for timing and the practice overlay.
/// Each layer uses the same columns; absent samples leave their column empty.
struct TimingWaveformBars: View {
  let height: (Int, Int, CGSize) -> CGFloat?
  let color: (CGFloat) -> Color

  var body: some View {
    Canvas { context, size in
      let columns = TimingWaveformBarLayout(width: size.width)
      let count = columns.count
      for index in 0..<count {
        guard let value = height(index, count, size), value.isFinite else { continue }
        let h = min(size.height, max(2, value))
        let x = columns.start + CGFloat(index) * 8
        let rect = CGRect(x: x - 1.5, y: (size.height - h) / 2, width: 3, height: h)
        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color(x)))
      }
    }
    .clipped()
    .accessibilityHidden(true)
  }
}

struct TimingWaveformBarLayout {
  let width: CGFloat
  var count: Int { max(1, Int((width - 20) / 8)) }
  var start: CGFloat { (width - CGFloat(count - 1) * 8) / 2 }
  var span: CGFloat { CGFloat(count - 1) * 8 }
  func x(at fraction: Double) -> CGFloat { start + CGFloat(fraction) * span }
  func fraction(at x: CGFloat) -> Double {
    min(1, max(0, Double((x - start) / max(1, span))))
  }
}
