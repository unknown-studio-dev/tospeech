import SwiftUI

private struct EchoReduceMotionKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Gallery override can only reduce motion; it never disables the system preference.
  var echoReduceMotion: Bool {
    get { self[EchoReduceMotionKey.self] }
    set { self[EchoReduceMotionKey.self] = newValue }
  }
}

enum EchoMotion {
  static let feedbackDuration = 0.12
  static let contentDuration = 0.16
  static let panelDuration = 0.20
  static func feedback(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: feedbackDuration)
  }
  static func content(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: contentDuration)
  }
}

struct EchoFocusRing: ViewModifier {
  var visible: Bool
  var radius: CGFloat = EchoMetrics.controlRadius
  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: radius + 1)
        .strokeBorder(visible ? EchoTheme.canvas : .clear, lineWidth: 1)
        .padding(-1)
        .allowsHitTesting(false)
      RoundedRectangle(cornerRadius: radius + 4)
        .strokeBorder(visible ? EchoTheme.focus : .clear, lineWidth: EchoMetrics.focusWidth)
        .padding(-3)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
  }
}

extension View {
  func echoFocusRing(_ visible: Bool, radius: CGFloat = EchoMetrics.controlRadius) -> some View {
    modifier(EchoFocusRing(visible: visible, radius: radius))
  }
}
