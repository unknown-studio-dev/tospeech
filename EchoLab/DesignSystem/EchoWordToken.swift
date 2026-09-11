import SwiftUI

enum EchoWordState: String, CaseIterable, Identifiable {
  case normal, selected, playing, needsTiming
  var id: String { rawValue }
}

/// A word and its IPA form one indivisible item in WordFlowLayout.
struct EchoWordToken: View {
  var word: String
  var ipa: String?
  var state: EchoWordState = .normal
  var showIPA = true
  var compact = false
  var readingScale: CGFloat = 1
  var sentenceSize: CGFloat = 30
  var ipaSize: CGFloat = 16
  var specimenWidth: CGFloat? = nil
  var preservesReadingContrastWhenDisabled = false
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Text(word).font(
          EchoFont.body(size: (compact ? 25 : sentenceSize) * readingScale, weight: .medium)
        )
        .foregroundStyle(
          !enabled && !preservesReadingContrastWhenDisabled
            ? EchoTheme.disabledText : state == .playing ? EchoTheme.accent : EchoTheme.text)
        if showIPA {
          Group {
            if let ipa { Text(verbatim: ipa) } else { EchoLocalizedText("Chưa có IPA") }
          }.font(EchoFont.body(size: (compact ? 13 : ipaSize) * readingScale))
            .foregroundStyle(state == .playing ? EchoTheme.accent : EchoTheme.secondaryText)
        }
      }.fixedSize().padding(EchoMetrics.wordPadding)
        .frame(width: specimenWidth)
        .background(
          background,
          in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
            .strokeBorder(
              state == .selected ? EchoTheme.focus : .clear)
        )
        .overlay(alignment: .bottom) {
          if state == .playing {
            Rectangle().fill(EchoTheme.accent).frame(height: 2).padding(.horizontal, 12).padding(
              .bottom, 5)
          }
        }
        .contentShape(Rectangle())
    }.buttonStyle(ReadingTokenButtonStyle()).focused($focused).focusEffectDisabled()
      .echoFocusRing(focused && enabled).onHover { hovered = $0 }
      .accessibilityLabel(word).echoAccessibilityValue(accessibilityStatus)
      .echoAccessibilityHint(
        state == .needsTiming
          ? "Nghe trong ngữ cảnh; cần chỉnh timing" : "Nghe audio gốc và mở phát âm"
      )
      .echoHelp(
        state == .needsTiming ? "Cần chỉnh timing · Nghe trong ngữ cảnh" : "Nghe từ trong audio gốc"
      )
  }
  private var background: Color {
    if state == .playing { return EchoTheme.selection }
    if state == .selected || (hovered && enabled) { return EchoTheme.raised }
    return EchoTheme.surface
  }
  private var accessibilityStatus: String {
    switch state {
    case .normal: ipa == nil ? "Chưa có IPA" : ""
    case .selected: "Đã chọn"
    case .playing: "Đang nghe"
    case .needsTiming: "Cần chỉnh timing"
    }
  }
}

private struct ReadingTokenButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    // Disabling playback must not dim the sentence the learner is reading aloud.
    configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
  }
}
