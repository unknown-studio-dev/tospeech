import SwiftUI

/// A native disclosure whose entire header participates in pointer and keyboard input.
struct EchoDisclosureGroup<Content: View>: View {
  var title: String
  var isExpanded: Binding<Bool>?
  @ViewBuilder var content: Content
  @State private var expanded = false

  init(_ title: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    DisclosureGroup(isExpanded: isExpanded ?? $expanded) {
      content
    } label: {
      EchoLocalizedText(title)
    }.disclosureGroupStyle(EchoDisclosureStyle())
  }
}

private struct EchoDisclosureStyle: DisclosureGroupStyle {
  @Environment(\.isEnabled) private var enabled
  @FocusState private var focused: Bool
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack(spacing: 6) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold)).frame(width: 14).accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(hovered && enabled ? EchoTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).focused($focused).focusEffectDisabled()
      .echoFocusRing(focused && enabled)
      .echoAccessibilityValue(configuration.isExpanded ? "disclosure.expanded" : "disclosure.collapsed")
      .onHover { hovered = $0 }
      if configuration.isExpanded {
        configuration.content.echoContentReveal(value: true, animateOnAppear: true)
      }
    }
  }
}

struct EchoSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  var options: [(Value, String)]
  var fillsWidth = true
  var labelSize: CGFloat = 13
  var horizontalPadding: CGFloat = 12
  @Environment(\.isEnabled) private var enabled
  @FocusState private var focused: Value?
  @State private var hovered: Value?

  var body: some View {
    HStack(spacing: 4) {
      ForEach(options, id: \.0) { value, title in
        Button {
          selection = value
        } label: {
          EchoLocalizedText(title).font(EchoFont.body(size: labelSize)).lineLimit(1)
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil).frame(height: 28)
            .foregroundStyle(
              !enabled
                ? EchoTheme.disabledText : EchoTheme.text
            )
            .background(
              selection == value || (hovered == value && enabled) ? EchoTheme.hover : .clear,
              in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused, equals: value).focusEffectDisabled()
        .onHover { hovered = $0 ? value : nil }
        .echoFocusRing(focused == value && enabled)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
        .onKeyPress(.rightArrow) {
          step(from: value, by: 1)
          return .handled
        }
        .onKeyPress(.leftArrow) {
          step(from: value, by: -1)
          return .handled
        }
      }
    }.padding(4).background(
      EchoTheme.surface, in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
  }

  private func step(from value: Value, by delta: Int) {
    guard enabled, let index = options.firstIndex(where: { $0.0 == value }) else { return }
    let next = options[(index + delta + options.count) % options.count].0
    selection = next
    focused = next
  }
}

struct EchoToggleStyle: ToggleStyle {
  var showsLabel = true
  var minimumHeight: CGFloat = 32
  var fillsWidth = false
  var contentPadding: CGFloat = 0
  var labelFirst = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
  @FocusState private var focused: Bool
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 8) {
        if showsLabel && labelFirst { configuration.label; Spacer(minLength: 8) }
        Capsule().fill(
          !enabled
            ? EchoTheme.hover
            : configuration.isOn
              ? (hovered ? EchoTheme.accentHover : EchoTheme.accent) : EchoTheme.border
        )
        .frame(width: 36, height: 20)
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(configuration.isOn && enabled ? EchoTheme.onAccent : EchoTheme.text)
            .frame(width: 16, height: 16).padding(2)
        }
        .animation(EchoMotion.feedback(reduceMotion: reduceMotion), value: configuration.isOn)
        if showsLabel && !labelFirst { configuration.label }
      }.frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: minimumHeight, alignment: .leading)
        .padding(contentPadding)
        .foregroundStyle(enabled ? EchoTheme.text : EchoTheme.disabledText)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focused($focused).focusEffectDisabled().echoFocusRing(focused && enabled)
    .onHover { hovered = $0 && enabled }
    .accessibilityRepresentation {
      Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
        configuration.label
      }.toggleStyle(.switch)
    }
  }
}

/// Two named modes share the same switch, sizing and surface as other toolbar controls.
struct EchoModeSwitch: View {
  var leadingTitle: String
  var trailingTitle: String
  @Binding var isOn: Bool
  var size: EchoControlSize = .regular
  var identifier = "mode-switch"
  @Environment(\.isEnabled) private var enabled
  @Environment(\.locale) private var locale

  var body: some View {
    HStack(spacing: EchoMetrics.controlGap) {
      EchoLocalizedText(leadingTitle)
        .foregroundStyle(labelColor(selected: !isOn))
      Toggle(isOn: $isOn) {
        Text("\(EchoLocalization.string(leadingTitle, locale: locale)) / \(EchoLocalization.string(trailingTitle, locale: locale))")
      }
      .toggleStyle(EchoToggleStyle(showsLabel: false, minimumHeight: size.height))
      .accessibilityIdentifier(identifier)
      EchoLocalizedText(trailingTitle)
        .foregroundStyle(labelColor(selected: isOn))
    }
    .font(EchoFont.body(size: size == .compact ? 13 : 14, weight: .semibold))
    .padding(.horizontal, 14)
    .frame(height: size.height)
    .background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
    .fixedSize()
    .accessibilityElement(children: .contain)
  }

  private func labelColor(selected: Bool) -> Color {
    enabled ? (selected ? EchoTheme.text : EchoTheme.secondaryText) : EchoTheme.disabledText
  }
}

struct EchoCheckbox: View {
  var title: String
  @Binding var isOn: Bool
  @Binding var isMixed: Bool
  @FocusState private var focused: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  init(title: String, isOn: Binding<Bool>, isMixed: Binding<Bool> = .constant(false)) {
    self.title = title
    _isOn = isOn
    _isMixed = isMixed
  }
  var body: some View {
    Button {
      isOn = isMixed ? true : !isOn
      isMixed = false
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isMixed ? "minus.square" : isOn ? "checkmark.square" : "square")
          .font(.system(size: 18)).frame(width: 18, height: 18)
          .foregroundStyle(
            enabled ? (hovered ? EchoTheme.accentHover : EchoTheme.accent) : EchoTheme.disabledText)
        EchoLocalizedText(title).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
      }.frame(minHeight: 32).contentShape(Rectangle())
    }.buttonStyle(.plain).focused($focused).focusEffectDisabled().echoFocusRing(focused && enabled)
      .onHover { hovered = $0 && enabled }
      .accessibilityRepresentation {
        Toggle(
          isOn: Binding(
            get: { isOn },
            set: {
              isOn = $0
              isMixed = false
            })
        ) { EchoLocalizedText(title) }
        .toggleStyle(.checkbox).echoAccessibilityValue(
          isMixed ? "Mixed" : isOn ? "Checked" : "Unchecked")
      }
  }
}

struct EchoChoice<Value: Hashable>: Identifiable {
  let id: Value
  let title: String
  let detail: String
}

extension EchoChoice: Sendable where Value: Sendable {}

struct EchoChoiceGroup<Value: Hashable>: View {
  var label: String
  @Binding var selection: Value
  var options: [EchoChoice<Value>]
  @FocusState private var focused: Value?
  @Environment(\.isEnabled) private var enabled
  @State private var hovered: Value?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(options) { option in
        Button {
          selection = option.id
        } label: {
          HStack(spacing: 16) {
            Image(systemName: selection == option.id ? "largecircle.fill.circle" : "circle")
              .font(.system(size: 20)).foregroundStyle(
                selection == option.id ? EchoTheme.accent : EchoTheme.secondaryText
              )
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
              EchoLocalizedText(option.title).font(EchoFont.body(size: 15, weight: .semibold))
              EchoLocalizedText(option.detail).font(EchoFont.body(size: 13))
                .foregroundStyle(EchoTheme.secondaryText).fixedSize(
                  horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.padding(16).frame(minHeight: 76)
            .foregroundStyle(enabled ? EchoTheme.text : EchoTheme.disabledText)
            .background(
              selection == option.id
                ? EchoTheme.selection
                : hovered == option.id && enabled ? EchoTheme.hover : EchoTheme.surface,
              in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .stroke(selection == option.id ? EchoTheme.accent : EchoTheme.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused, equals: option.id).focusEffectDisabled()
          .onHover { hovered = $0 ? option.id : nil }
          .echoFocusRing(focused == option.id && enabled, radius: 10)
          .accessibilityAddTraits(selection == option.id ? .isSelected : [])
          .onKeyPress(.downArrow) {
            step(from: option.id, by: 1)
            return .handled
          }
          .onKeyPress(.upArrow) {
            step(from: option.id, by: -1)
            return .handled
          }
      }
    }.accessibilityElement(children: .contain).echoAccessibilityLabel(label)
  }

  private func step(from value: Value, by delta: Int) {
    guard enabled, let index = options.firstIndex(where: { $0.id == value }) else { return }
    let next = options[(index + delta + options.count) % options.count].id
    selection = next
    focused = next
  }
}
