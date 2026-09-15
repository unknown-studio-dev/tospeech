import SwiftUI

/// Multiline, keyboard-first input using shared field chrome. Disables writing
/// assistance for listening exercises; focus follows explicit editing availability.
struct EchoTextEditor: View {
  var label: String
  @Binding var text: String
  var placeholder: String
  var editable = true
  var focusID: String = ""
  @FocusState private var focused: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        EchoLocalizedText(placeholder).foregroundStyle(EchoTheme.muted)
          .padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
      }
      TextEditor(text: $text)
        .scrollContentBackground(.hidden)
        .autocorrectionDisabled(true)
        .focused($focused).focusEffectDisabled()
        .disabled(!editable)
        .echoAccessibilityLabel(label)
    }
    .font(EchoFont.body(size: 18)).foregroundStyle(EchoTheme.text)
    .padding(8).frame(minHeight: 88, maxHeight: 132)
    .background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
    .overlay(EchoFieldBorder(state: .idle, focused: focused, enabled: editable))
    .onChange(of: editable, initial: true) { _, value in focused = value }
    .onChange(of: focusID) { _, _ in focused = editable }
  }
}
