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
          HStack(alignment: .center, spacing: 5) {
            ForEach(0..<max(1, Int((width - 20) / 8)), id: \.self) { index in
              let position = CGFloat(index * 8 + 10)
              Capsule().fill(
                position >= startX && position <= endX
                  ? EchoTheme.accent : EchoTheme.text.opacity(0.28)
              ).frame(width: 3, height: barHeight(index: index, width: width, height: proxy.size.height))
            }
          }.frame(maxWidth: .infinity).padding(.horizontal, 10).clipped()
        } else if let loadError {
          HStack(spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
              .foregroundStyle(EchoTheme.caution)
            Text(loadError).font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.secondaryText)
              .lineLimit(2)
            Spacer()
            if let onRetry { EchoButton("Retry", symbol: "arrow.clockwise", action: onRetry) }
          }.padding(.horizontal, 14)
        } else {
          HStack(spacing: 8) {
            if loading { EchoSpinner() }
            Text("Preparing waveform from local audio…")
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
      .accessibilityLabel(isStart ? "Start timing handle" : "End timing handle")
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
