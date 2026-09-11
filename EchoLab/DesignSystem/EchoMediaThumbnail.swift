import SwiftUI

/// The same thumbnail/open/delete/duration composition for Library and Resume.
/// Callers own confirmation and deletion; this component only emits actions.
struct EchoMediaThumbnail: View {
  var name: String
  var title: String
  var duration: String
  var onOpen: () -> Void
  var onDelete: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.locale) private var locale

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onOpen) {
        EchoThumbnail(name: name, title: title)
      }
      .buttonStyle(EchoThumbnailButtonStyle())
      .focused($focused).focusEffectDisabled()
      .overlay(EchoFieldBorder(focused: focused, enabled: enabled, radius: 12).opacity(focused ? 1 : 0))
      .accessibilityLabel(EchoLocalization.format("Open lesson: %@", locale: locale, arguments: [title]))
      EchoIconButton(
        symbol: "trash",
        label: EchoLocalization.format("Delete lesson: %@", locale: locale, arguments: [title]),
        dark: true,
        action: onDelete
      )
        .padding(8)
      Text(duration).font(EchoFont.mono(size: 10, weight: .medium)).foregroundStyle(EchoTheme.text)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(EchoTheme.mediaScrim, in: RoundedRectangle(cornerRadius: 5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(8).allowsHitTesting(false)
    }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

private struct EchoThumbnailButtonStyle: ButtonStyle {
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.8 : hovered ? 0.92 : 1)
      .onHover { hovered = $0 && enabled }
  }
}
