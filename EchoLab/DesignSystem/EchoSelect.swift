import SwiftUI

struct EchoSelect: View {
  var label: String
  @Binding var selection: String
  var options: [(id: String, title: String)]
  @State private var expanded = false
  @State private var hovered = false
  @State private var focusedIndex = 0
  @State private var triggerWidth: CGFloat = 280
  @FocusState private var listFocused: Bool
  @FocusState private var triggerFocused: Bool
  var state: EchoControlState = .idle
  var size: EchoControlSize = .compact
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  var body: some View {
    Button {
      focusedIndex = options.firstIndex { $0.id == selection } ?? 0
      expanded.toggle()
    } label: {
      HStack(spacing: 12) {
        EchoLocalizedText(options.first { $0.id == selection }?.title ?? label).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: state.isLoading ? "hourglass" : "chevron.down").font(
          EchoFont.body(size: 11, weight: .semibold)
        )
        .frame(width: 14, height: 14).foregroundStyle(
          unavailable ? EchoTheme.disabledText : EchoTheme.secondaryText
        )
        .accessibilityHidden(true)
      }.font(EchoFont.body(size: size == .compact ? 13 : 14)).padding(.horizontal, 10).frame(minHeight: size.height)
        .background(
          hovered && !unavailable && !triggerFocused ? EchoTheme.hover : EchoTheme.surface,
          in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
        )
        .overlay(EchoFieldBorder(state: state, focused: triggerFocused, enabled: !unavailable))
    }.buttonStyle(.plain).echoAccessibilityLabel(label)
      .echoAccessibilityValue(options.first { $0.id == selection }?.title ?? label)
      .echoAccessibilityHint(
        state.message ?? "Use arrow keys to choose, Return to select, Escape to close."
      )
      .focused($triggerFocused).focusEffectDisabled()
      .foregroundStyle(enabled && !state.blocksAction ? EchoTheme.text : EchoTheme.disabledText)
      .disabled(options.isEmpty || state.blocksAction)
      .echoHelp(state.message ?? label)
      .onHover { hovered = $0 }
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { triggerWidth = $0 }
      .onKeyPress(.downArrow) { openMenu() }
      .onKeyPress(.upArrow) { openMenu() }
      .animation(
        EchoMotion.feedback(reduceMotion: reduceMotion || previewReduceMotion), value: hovered
      )
      .onChange(of: expanded) { _, isOpen in if !isOpen && !unavailable { triggerFocused = true } }
      .onChange(of: options.map(\.id)) { _, _ in
        focusedIndex = min(max(0, focusedIndex), max(0, options.count - 1))
        if options.isEmpty { expanded = false }
      }
      .popover(isPresented: $expanded, arrowEdge: .bottom) {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: EchoMetrics.menuGap) {
              ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button {
                  selection = option.id
                  expanded = false
                } label: {
                  EchoSelectOptionLabel(
                    title: option.title, selected: selection == option.id,
                    highlighted: focusedIndex == index)
                }.buttonStyle(.plain).id(index)
                  .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                  .onHover { hovering in if hovering { focusedIndex = index } }
              }
            }.padding(EchoMetrics.menuPadding)
          }.frame(width: max(160, triggerWidth), height: menuHeight)
            .focusable().focused($listFocused).focusEffectDisabled()
            .onAppear {
              listFocused = true
              proxy.scrollTo(focusedIndex)
            }
            .onKeyPress(.downArrow) {
              focusedIndex = min(options.count - 1, focusedIndex + 1)
              proxy.scrollTo(focusedIndex)
              return .handled
            }
            .onKeyPress(.upArrow) {
              focusedIndex = max(0, focusedIndex - 1)
              proxy.scrollTo(focusedIndex)
              return .handled
            }
            .onKeyPress(.return) {
              if options.indices.contains(focusedIndex) { selection = options[focusedIndex].id }
              expanded = false
              return .handled
            }
            .onExitCommand { expanded = false }
        }.background(EchoTheme.raised).foregroundStyle(EchoTheme.text)
          .font(EchoFont.body(size: 13)).preferredColorScheme(.dark)
      }
  }

  private var unavailable: Bool { !enabled || options.isEmpty || state.blocksAction }
  private var menuHeight: CGFloat {
    min(
      310,
      CGFloat(options.count) * EchoMetrics.menuRowHeight + CGFloat(max(0, options.count - 1))
        * EchoMetrics.menuGap + 2 * EchoMetrics.menuPadding)
  }
  private func openMenu() -> KeyPress.Result {
    guard !unavailable else { return .ignored }
    focusedIndex = options.firstIndex { $0.id == selection } ?? 0
    expanded = true
    return .handled
  }
}

struct EchoSelectOptionLabel: View {
  var title: String
  var selected: Bool
  var highlighted: Bool
  var body: some View {
    HStack(spacing: 16) {
      EchoLocalizedText(title).font(EchoFont.body(size: 13)).lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
        .foregroundStyle(EchoTheme.accent).opacity(selected ? 1 : 0)
        .frame(width: 14, height: 14).accessibilityHidden(true)
    }.padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: EchoMetrics.menuRowHeight, alignment: .leading)
      .background(highlighted ? EchoTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
  }
}
