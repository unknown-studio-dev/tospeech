import SwiftUI

struct EchoTextField: View {
  var label: String
  @Binding var text: String
  var placeholder = ""
  var helper = ""
  var state: EchoControlState = .idle
  var readOnly = false
  var size: EchoControlSize = .compact
  var onEndEditing: () -> Void = {}
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText(label).font(EchoFont.body(size: 13, weight: .medium))
      HStack(spacing: 8) {
        if readOnly {
          Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } else {
          TextField(text: $text) { EchoLocalizedText(placeholder) }
            .textFieldStyle(.plain).focused($focused)
            .focusEffectDisabled()
            .echoAccessibilityLabel(label).echoAccessibilityHint(state.message ?? helper)
        }
        statusIcon.frame(width: 20, height: 20)
      }
      .font(EchoFont.body(size: 13)).padding(.horizontal, 10).frame(height: size.height)
      .foregroundStyle(unavailable ? EchoTheme.disabledText : EchoTheme.text)
      .background(
        hovered && !unavailable && !focused ? EchoTheme.hover : EchoTheme.surface,
        in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
      )
      .overlay(
        EchoFieldBorder(state: state, focused: focused && !readOnly, enabled: !unavailable)
      )
      .onHover { hovered = $0 }
      .animation(EchoMotion.feedback(reduceMotion: reduceMotion), value: hovered)
      .disabled(unavailable)
      EchoLocalizedText(state.message ?? helper)
        .font(EchoFont.metadata).foregroundStyle(messageColor)
        .frame(minHeight: 16, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
    }.foregroundStyle(EchoTheme.text)
      .onChange(of: focused) { wasFocused, isFocused in
        if wasFocused && !isFocused { onEndEditing() }
      }
  }

  private var unavailable: Bool {
    !enabled || { if case .disabled = state { true } else { false } }()
  }
  private var messageColor: Color {
    switch state {
    case .error: EchoTheme.danger
    case .success: EchoTheme.success
    default: EchoTheme.secondaryText
    }
  }
  @ViewBuilder private var statusIcon: some View {
    switch state {
    case .loading:
      if reduceMotion {
        Image(systemName: "hourglass")
      } else {
        SwiftUI.ProgressView().controlSize(.mini)
      }
    case .error: Image(systemName: "exclamationmark.circle").foregroundStyle(EchoTheme.danger)
    case .success: Image(systemName: "checkmark.circle").foregroundStyle(EchoTheme.success)
    case .disabled: Image(systemName: "lock")
    case .idle:
      if readOnly {
        Image(systemName: "lock")
      } else if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain).accessibilityHidden(false)
        .echoAccessibilityLabel("Clear")
      }
    }
  }
}
