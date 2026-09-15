import AppKit
import SwiftUI

struct EchoPanel<Content: View>: View {
  var padding: CGFloat = 24
  var verticalPadding: CGFloat? = nil
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(.horizontal, padding).padding(.vertical, verticalPadding ?? padding).frame(
      maxWidth: .infinity, alignment: .leading
    )
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: EchoTheme.radius))
  }
}

struct Eyebrow: View {
  var text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    EchoLocalizedText(text).textCase(.uppercase).font(EchoFont.body(size: 11, weight: .medium)).tracking(1.3)
      .foregroundStyle(EchoTheme.muted)
  }
}

struct EchoBadge: View {
  var text: String
  var warning = false
  init(_ text: String, warning: Bool = false) {
    self.text = text
    self.warning = warning
  }
  var body: some View {
    EchoLocalizedText(text).font(EchoFont.body(size: 11, weight: .medium)).padding(.horizontal, 9).padding(
      .vertical, 5
    )
    .foregroundStyle(warning ? EchoTheme.caution : EchoTheme.muted)
    .background(warning ? EchoTheme.warning : EchoTheme.soft, in: RoundedRectangle(cornerRadius: 6))
  }
}

struct EchoNotice: View {
  var text: String
  var copy: EchoCopy?
  var error = false

  init(text: String, error: Bool = false) {
    self.text = text
    self.error = error
  }

  init(copy: EchoCopy, error: Bool = false) {
    text = copy.key
    self.copy = copy
    self.error = error
  }

  var body: some View {
    Label {
      Group {
        if let copy { EchoLocalizedText(copy) } else { EchoLocalizedText(text) }
      }.fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: error ? "exclamationmark.triangle" : "info.circle")
    }
      .font(EchoFont.body(size: 12)).foregroundStyle(error ? EchoTheme.danger : EchoTheme.muted)
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        error ? EchoTheme.errorSurface : EchoTheme.soft,
        in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
  }
}

struct EchoSearchField: View {
  var placeholder: String
  @Binding var text: String
  var size: EchoControlSize = .compact
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  @State private var hovered = false
  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: "magnifyingglass").frame(width: 14, height: 14).foregroundStyle(
        EchoTheme.muted)
      TextField(text: $text) { EchoLocalizedText(placeholder) }
        .textFieldStyle(.plain).echoAccessibilityLabel(placeholder)
        .focused($focused).focusEffectDisabled()
      ZStack {
        if !text.isEmpty {
          Button {
            text = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain).echoHelp("Clear search").echoAccessibilityLabel("Clear search")
        }
      }.frame(width: 20, height: 20)
    }.font(EchoFont.body(size: 13)).padding(.horizontal, 10).frame(
      height: size.height
    ).background(
      hovered && enabled && !focused ? EchoTheme.hover : EchoTheme.surface,
      in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
    )
    .foregroundStyle(enabled ? EchoTheme.text : EchoTheme.disabledText)
    .overlay(EchoFieldBorder(focused: focused, enabled: enabled))
    .onHover { hovered = $0 }
    .animation(
      EchoMotion.feedback(reduceMotion: systemReduceMotion || previewReduceMotion), value: hovered)
  }
}

struct EchoThumbnail: View {
  var name: String
  var title: String
  var body: some View {
    GeometryReader { geometry in
      if let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
        let image = NSImage(contentsOf: url)
      {
        Image(nsImage: image).resizable().scaledToFill().frame(
          width: geometry.size.width, height: geometry.size.height
        ).clipped()
      } else {
        ZStack {
          EchoTheme.selected
          VStack(spacing: 8) {
            Image(systemName: "waveform").font(.largeTitle)
            Text(verbatim: title).font(.caption).multilineTextAlignment(.center)
          }.padding()
        }
      }
    }.accessibilityLabel(title).clipped()
  }
}

struct EchoEmptyState: View {
  var title: String
  var message: String
  var symbol = "waveform"
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol).font(EchoFont.body(size: 24)).foregroundStyle(EchoTheme.muted)
        .frame(width: 24, height: 24).accessibilityHidden(true)
      EchoLocalizedText(title).font(EchoFont.body(size: 16, weight: .semibold))
      EchoLocalizedText(message).font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: EchoMetrics.panelRadius))
  }
}

struct EchoSheet<Content: View>: View {
  var eyebrow: String? = nil
  var title: String
  var subtitle: String
  var width: CGFloat = 640
  var minimumHeight: CGFloat? = nil
  var close: () -> Void
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 7) {
          if let eyebrow { Eyebrow(eyebrow) }
          EchoLocalizedText(title).font(EchoFont.heading(size: 22, weight: .semibold))
          EchoLocalizedText(subtitle).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.muted)
        }
        Spacer()
        EchoIconButton(symbol: "xmark", label: "Close", action: close)
      }
      content
    }.padding(24).frame(width: width).frame(minHeight: minimumHeight, alignment: .top)
      .background(EchoTheme.raised).foregroundStyle(EchoTheme.ink)
      .environment(\.echoControlSurface, EchoTheme.surface)
      .preferredColorScheme(.dark)
  }
}
