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

/// Reveals only the current content. Changing the key never remounts a child or
/// keeps an outgoing text layer alive; layout commits before the opacity animation.
private struct EchoContentReveal<Key: Hashable>: ViewModifier {
  let value: Key
  let enabled: Bool
  @State private var revealed: Key?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion

  init(value: Key, enabled: Bool, animateOnAppear: Bool) {
    self.value = value
    self.enabled = enabled
    _revealed = State(initialValue: animateOnAppear ? nil : value)
  }

  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

  func body(content: Content) -> some View {
    content
      .transition(.identity)
      .transaction { $0.animation = nil }
      .opacity(reduceMotion || !enabled || revealed == value ? 1 : 0)
      .animation(nil, value: value)
      .animation(nil, value: reduceMotion || !enabled)
      .task(id: value) {
        guard revealed != value else { return }
        // Yield one layout pass; no artificial delay of loading, focus or media.
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(EchoMotion.content(reduceMotion: reduceMotion || !enabled)) {
          revealed = value
        }
      }
  }
}

extension View {
  func echoContentReveal<Key: Hashable>(value: Key, enabled: Bool = true,
    animateOnAppear: Bool = false) -> some View {
    modifier(EchoContentReveal(value: value, enabled: enabled, animateOnAppear: animateOnAppear))
  }
}
