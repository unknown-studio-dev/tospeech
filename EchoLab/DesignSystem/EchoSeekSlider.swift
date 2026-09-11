import SwiftUI

/// Displays source time; its owner decides whether seeking is allowed and how it is played.
struct EchoSeekSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double>
  @State private var hovering = false
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled

  private var fraction: Double {
    guard range.upperBound > range.lowerBound else { return 0 }
    return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(EchoTheme.border).frame(height: 3)
        Capsule().fill(enabled ? EchoTheme.accent : EchoTheme.disabledText)
          .frame(width: geometry.size.width * fraction, height: 3)
        if hovering || focused {
          Circle().fill(EchoTheme.accent).frame(width: 8, height: 8)
            .offset(
              x: min(max(0, geometry.size.width * fraction - 4), max(0, geometry.size.width - 8)))
        }
      }.frame(height: 16).contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { drag in
            guard enabled, geometry.size.width > 0 else { return }
            let position = min(1, max(0, drag.location.x / geometry.size.width))
            value = range.lowerBound + position * (range.upperBound - range.lowerBound)
          })
    }.frame(height: 16).focusable(enabled).focused($focused).focusEffectDisabled()
      .echoFocusRing(focused && enabled).onHover { hovering = $0 && enabled }
      .onKeyPress(.leftArrow) { adjust(-0.05) }
      .onKeyPress(.rightArrow) { adjust(0.05) }
      .echoHelp(EchoCopy(
        "seek.help", arguments: [.raw(EchoFormat.decimal(value))]))
      .accessibilityRepresentation {
        Slider(value: $value, in: range, step: 0.05) { Text("Vị trí trong audio gốc") }
      }
  }
  private func adjust(_ delta: Double) -> KeyPress.Result {
    guard enabled else { return .ignored }
    value = min(range.upperBound, max(range.lowerBound, value + delta))
    return .handled
  }
}
