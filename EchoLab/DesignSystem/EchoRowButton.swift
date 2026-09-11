import SwiftUI

/// Shared interaction chrome for content rows and navigation, without owning routing or data.
struct EchoRowButton<Content: View>: View {
  var selected = false
  var navigation = false
  var minimumHeight: CGFloat = 40
  var action: () -> Void
  @ViewBuilder var content: () -> Content
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      content()
        .font(EchoFont.body(size: 13, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(EchoRowButtonStyle(selected: selected, navigation: navigation))
    .focused($focused).focusEffectDisabled().echoFocusRing(focused && enabled)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct EchoRowButtonStyle: ButtonStyle {
  var selected: Bool
  var navigation: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(!enabled ? EchoTheme.disabledText : navigation ? (selected ? EchoTheme.accent : EchoTheme.secondaryText) : EchoTheme.text)
      .background(
        selected || (configuration.isPressed && enabled) ? EchoTheme.selection : hovered && enabled ? EchoTheme.hover : .clear,
        in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
      .onHover { hovered = $0 }
      .animation(EchoMotion.feedback(reduceMotion: systemReduceMotion || previewReduceMotion), value: hovered)
  }
}
