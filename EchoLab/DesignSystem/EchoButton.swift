import SwiftUI

private struct EchoControlSurfaceKey: EnvironmentKey {
  static let defaultValue = EchoTheme.raised
}

extension EnvironmentValues {
  /// Dialog containers set this once so secondary controls never blend into their backing.
  var echoControlSurface: Color {
    get { self[EchoControlSurfaceKey.self] }
    set { self[EchoControlSurfaceKey.self] = newValue }
  }
}

enum EchoButtonKind: String, CaseIterable {
  case primary, secondary, danger, destructive, ghost, dark
}

/// Only the component gallery supplies a forced interaction; app controls use live input.
enum EchoInteractionPreview: String, CaseIterable, Identifiable {
  case rest, hover, pressed, focused
  var id: String { rawValue }
}

struct EchoButtonStyle: ButtonStyle {
  @Environment(\.echoControlSurface) private var containerSurface
  var kind: EchoButtonKind = .secondary
  var size: EchoControlSize = .compact
  var preview: EchoInteractionPreview = .rest
  var state: EchoControlState = .idle
  var minimumWidth: CGFloat? = nil
  var surface: Color? = nil
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed || preview == .pressed
    configuration.label
      .font(EchoFont.body(size: size == .compact ? 13 : 14, weight: .semibold))
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 14).frame(minWidth: minimumWidth, minHeight: size.height)
      .foregroundStyle(state.isLoading ? foreground : enabled ? foreground : EchoTheme.disabledText)
      .background(
        background(pressed: pressed), in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
      )
      .contentShape(RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
      .animation(pressed ? nil : EchoMotion.feedback(reduceMotion: reduceMotion), value: hovered)
      .onHover { hovered = $0 && enabled }
  }

  private var foreground: Color {
    if case .success = state { return EchoTheme.onAccent }
    switch kind {
    case .primary, .destructive: return EchoTheme.onAccent
    case .danger: return EchoTheme.danger
    default: return EchoTheme.text
    }
  }

  private func background(pressed: Bool) -> Color {
    if state.isLoading { return kind == .primary ? EchoTheme.accent : surface ?? containerSurface }
    guard enabled else { return surface ?? containerSurface }
    if case .success = state { return EchoTheme.success }
    let hover = hovered || preview == .hover
    switch kind {
    case .primary:
      return pressed ? EchoTheme.accentPressed : hover ? EchoTheme.accentHover : EchoTheme.accent
    case .danger: return pressed || hover ? EchoTheme.errorSurface : surface ?? containerSurface
    case .destructive: return pressed ? EchoTheme.danger.opacity(0.8) : EchoTheme.danger
    case .ghost: return pressed ? EchoTheme.selection : hover ? EchoTheme.hover : .clear
    case .secondary, .dark:
      return pressed ? EchoTheme.selection : hover ? EchoTheme.hover : surface ?? containerSurface
    }
  }
}

struct EchoButton: View {
  var title: String
  var symbol: String?
  var kind: EchoButtonKind
  var size: EchoControlSize
  var state: EchoControlState
  var preview: EchoInteractionPreview
  var loadingTitle: String?
  var minimumWidth: CGFloat?
  var surface: Color?
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

  init(
    _ title: String, symbol: String? = nil, kind: EchoButtonKind = .secondary,
    size: EchoControlSize = .compact, state: EchoControlState = .idle,
    preview: EchoInteractionPreview = .rest, loadingTitle: String? = nil,
    minimumWidth: CGFloat? = nil,
    surface: Color? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.symbol = symbol
    self.kind = kind
    self.size = size
    self.state = state
    self.preview = preview
    self.loadingTitle = loadingTitle
    self.minimumWidth = minimumWidth
    self.surface = surface
    self.action = action
  }

  var body: some View {
    Button {
      if !state.blocksAction { action() }
    } label: {
      HStack(spacing: EchoMetrics.controlGap) {
        if symbol != nil || loadingTitle != nil || state != .idle {
          ZStack {
            if state.isLoading && !reduceMotion {
              SwiftUI.ProgressView().controlSize(.mini)
                .tint(kind == .primary ? EchoTheme.onAccent : EchoTheme.text)
                .environment(\.colorScheme, kind == .primary ? .light : .dark).disabled(false)
            } else {
              Image(systemName: stateIcon).font(.system(size: iconSize, weight: .medium))
            }
          }.frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        }
        ZStack {
          EchoLocalizedText(title).hidden()
          if let loadingTitle { EchoLocalizedText(loadingTitle).hidden() }
          EchoLocalizedText(displayTitle)
        }.fixedSize(horizontal: true, vertical: false)
      }
    }
    .buttonStyle(
      EchoButtonStyle(
        kind: effectiveKind, size: size, preview: preview, state: state, minimumWidth: minimumWidth,
        surface: surface)
    )
    .focused($focused).focusEffectDisabled()
    .echoFocusRing((focused || preview == .focused) && enabled && !state.blocksAction)
    .disabled(state.blocksAction)
    .echoAccessibilityLabel(displayTitle)
    .echoAccessibilityHint(state.message ?? "")
    .echoHelp(state.message ?? title)
  }

  private var displayTitle: String {
    switch state {
    case .loading(let label), .success(let label): label
    default: title
    }
  }
  private var iconSize: CGFloat {
    size == .compact ? EchoMetrics.compactIcon : EchoMetrics.controlIcon
  }
  private var effectiveKind: EchoButtonKind {
    if case .error = state { .danger } else { kind }
  }
  private var stateIcon: String {
    switch state {
    case .loading: "hourglass"
    case .error: "exclamationmark.triangle"
    case .success: "checkmark"
    default: symbol ?? "lock"
    }
  }
}

struct EchoIconButton: View {
  var symbol: String
  var label: String
  var dark = false
  var size: EchoControlSize = .compact
  var surface: Color? = nil
  var preview: EchoInteractionPreview = .rest
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium))
        .frame(width: size.height, height: size.height)
        .contentShape(Rectangle())
    }
    .buttonStyle(EchoIconButtonStyle(dark: dark, surface: surface, preview: preview))
    .focused($focused).focusEffectDisabled()
    .overlay(
      EchoFieldBorder(focused: focused || preview == .focused, enabled: enabled)
        .opacity((focused || preview == .focused) && enabled ? 1 : 0)
    )
    .echoHelp(label).echoAccessibilityLabel(label)
  }
}

private struct EchoIconButtonStyle: ButtonStyle {
  @Environment(\.echoControlSurface) private var containerSurface
  var dark: Bool
  var surface: Color?
  var preview: EchoInteractionPreview
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? EchoTheme.text : EchoTheme.disabledText)
      .background(
        !enabled
          ? surface ?? containerSurface
          : configuration.isPressed || preview == .pressed
            ? EchoTheme.selection
            : hovered || preview == .hover
              ? EchoTheme.hover : surface ?? (dark ? EchoTheme.canvas : containerSurface),
        in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
      )
      .animation(
        configuration.isPressed ? nil : EchoMotion.feedback(reduceMotion: reduceMotion),
        value: hovered
      )
      .onHover { hovered = $0 && enabled }
  }
}
