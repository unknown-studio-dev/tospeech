import SwiftUI

/// D00 slider geometry; source seeking continues to use its separate audio-time control.
struct EchoSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double>
  var step: Double
  var label: String
  var valueLabel: String
  var previewFocused = false
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false

  private var fraction: CGFloat {
    guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
    return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
  }

  var body: some View {
    GeometryReader { geometry in
      let travel = max(0, geometry.size.width - 24)
      let center = 12 + travel * fraction
      ZStack(alignment: .leading) {
        Capsule().fill(EchoTheme.border).frame(height: 4)
        Capsule().fill(enabled ? EchoTheme.accent : EchoTheme.disabledText)
          .frame(width: center, height: 4)
        Circle().fill(
          enabled ? (hovered ? EchoTheme.accentHover : EchoTheme.accent) : EchoTheme.disabledText
        )
        .frame(width: 12, height: 12).frame(width: 24, height: 24)
        .background(
          (focused || previewFocused) && enabled ? EchoTheme.canvas : .clear, in: Circle()
        )
        .overlay(
          Circle().strokeBorder(
            (focused || previewFocused) && enabled ? EchoTheme.focus : .clear, lineWidth: 2)
        )
        .offset(x: center - 12)
      }.frame(height: 24).contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { drag in
            guard enabled, travel > 0 else { return }
            focused = true
            set(
              range.lowerBound + Double(min(1, max(0, (drag.location.x - 12) / travel)))
                * (range.upperBound - range.lowerBound))
          })
    }.frame(height: 24).focusable(enabled).focused($focused).focusEffectDisabled()
      .onHover { hovered = $0 && enabled }
      .onKeyPress(.leftArrow) { adjust(-step) }
      .onKeyPress(.rightArrow) { adjust(step) }
      .onKeyPress(.downArrow) { adjust(-step) }
      .onKeyPress(.upArrow) { adjust(step) }
      .accessibilityRepresentation {
        Slider(value: $value, in: range, step: step) { EchoLocalizedText(label) }
          .accessibilityValue(valueLabel).disabled(!enabled)
      }
  }

  private func set(_ proposed: Double) {
    guard proposed.isFinite, step.isFinite, step > 0 else { return }
    let snapped = range.lowerBound + ((proposed - range.lowerBound) / step).rounded() * step
    value = min(range.upperBound, max(range.lowerBound, snapped))
  }
  private func adjust(_ delta: Double) -> KeyPress.Result {
    guard enabled else { return .ignored }
    set(value + delta)
    return .handled
  }
}
