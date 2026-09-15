import SwiftUI

/// Equal seconds occupy equal widths, making different speaking durations
/// visible without treating one speaker's timeline as the other's alignment.
struct ReviewComparisonTimeline: View {
  let sourceElapsed: Double
  let sourceDuration: Double
  let takeElapsed: Double
  let takeDuration: Double
  private var duration: Double { max(sourceDuration, takeDuration, 0.001) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      EchoLocalizedText("review.together_hint").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      row("review.source_left", elapsed: sourceElapsed, length: sourceDuration, color: EchoTheme.accent)
      row("review.take_right", elapsed: takeElapsed, length: takeDuration, color: EchoTheme.text)
    }
  }
  private func row(_ title: String, elapsed: Double, length: Double, color: Color) -> some View {
    HStack(spacing: 10) {
      EchoLocalizedText(title).frame(width: 110, alignment: .leading)
      GeometryReader { proxy in
        Capsule().fill(EchoTheme.separator)
          .frame(width: proxy.size.width * min(1, max(0, length / duration)))
          .overlay(alignment: .leading) {
            Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, elapsed / duration)))
          }
      }.frame(height: 4).accessibilityHidden(true)
      Text(verbatim: "\(EchoFormat.time(elapsed)) / \(EchoFormat.time(length))").monospacedDigit()
    }.font(EchoFont.metadata).foregroundStyle(color)
  }
}
