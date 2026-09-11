import SwiftUI

// D00 transport actions: shared chrome; playback callbacks stay in the feature.
struct EchoTransportButton: View {
  var symbol: String
  var title: String
  var width: CGFloat
  var height: CGFloat
  var primary = false
  var circular = false
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: symbol).font(.system(size: circular ? 20 : 18))
        if !circular { EchoLocalizedText(title).font(EchoFont.body(size: 15, weight: .semibold)).lineLimit(1) }
      }.frame(width: width, height: height)
    }.buttonStyle(EchoTransportButtonStyle(primary: primary, radius: circular ? 27 : 10))
      .focused($focused).focusEffectDisabled().echoFocusRing(
        focused && enabled, radius: circular ? 27 : 10
      )
      .echoAccessibilityLabel(title).echoHelp(title)
  }
}

/// D00 options trigger, with optional secondary speed caption.
struct EchoTransportOptionsButton: View {
  var title: String
  var subtitle: String? = nil
  var scale: CGFloat = 1
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          if subtitle == nil { Image(systemName: "repeat") }
          EchoLocalizedText(title).font(EchoFont.body(size: 15 * scale, weight: subtitle == nil ? .medium : .semibold)).lineLimit(1)
          if subtitle != nil { Image(systemName: "chevron.down").font(EchoFont.body(size: 10)) }
        }.frame(height: subtitle == nil ? 28 * scale : 32)
        if let subtitle {
          EchoLocalizedText(subtitle).font(EchoFont.body(size: 12 * scale)).foregroundStyle(EchoTheme.secondaryText)
        }
      }.contentShape(Rectangle())
    }
    .buttonStyle(EchoTransportButtonStyle(primary: false, radius: EchoMetrics.controlRadius))
    .focused($focused).focusEffectDisabled().echoFocusRing(focused && enabled)
    .echoAccessibilityLabel(title).echoAccessibilityHint("Playback and repeat options")
  }
}

private struct EchoTransportButtonStyle: ButtonStyle {
  var primary: Bool
  var radius: CGFloat
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        !enabled ? EchoTheme.disabledText : primary ? EchoTheme.onAccent : EchoTheme.text
      )
      .background(
        !enabled
          ? Color.clear
          : primary
            ? (configuration.isPressed
              ? EchoTheme.accentPressed : hovered ? EchoTheme.accentHover : EchoTheme.accent)
            : (configuration.isPressed ? EchoTheme.selection : hovered ? EchoTheme.hover : .clear),
        in: RoundedRectangle(cornerRadius: radius)
      )
      .onHover { hovered = $0 && enabled }
      .animation(
        configuration.isPressed
          ? nil : EchoMotion.feedback(reduceMotion: systemReduceMotion || previewReduceMotion),
        value: hovered)
  }
}
