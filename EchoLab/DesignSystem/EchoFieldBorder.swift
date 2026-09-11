import SwiftUI

/// One inset stroke replaces the resting border; validation errors take precedence over focus.
struct EchoFieldBorder: View {
  var state: EchoControlState = .idle
  var focused = false
  var enabled = true
  var radius: CGFloat = EchoMetrics.controlRadius

  var color: Color {
    if case .error = state { return EchoTheme.danger }
    if showsFocus { return EchoTheme.focus }
    return EchoTheme.border
  }

  var lineWidth: CGFloat { showsFocus ? EchoMetrics.focusWidth : 1 }

  private var showsFocus: Bool {
    guard enabled, focused else { return false }
    if case .disabled = state { return false }
    return true
  }

  var body: some View {
    RoundedRectangle(cornerRadius: radius)
      .strokeBorder(color, lineWidth: lineWidth)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .transaction { $0.animation = nil }
  }
}
