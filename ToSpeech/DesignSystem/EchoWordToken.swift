import SwiftUI

enum EchoWordState: String, CaseIterable, Identifiable {
  case normal, selected, playing, needsTiming
  var id: String { rawValue }
}

/// A word and its IPA form one indivisible item in WordFlowLayout.
struct EchoWordToken: View {
  var word: String
  var ipa: String?
  /// When the shown IPA comes from the other accent (the requested one had no
  /// entry), this holds that accent's label (e.g. "US"); the token dims the
  /// pronunciation and appends the marker so it is never mistaken for the
  /// requested accent.
  var ipaFallbackLabel: String? = nil
  var state: EchoWordState = .normal
  var showIPA = true
  var compact = false
  var readingScale: CGFloat = 1
  var sentenceSize: CGFloat = 30
  var ipaSize: CGFloat = 16
  var specimenWidth: CGFloat? = nil
  var preservesReadingContrastWhenDisabled = false
  var readOnly = false
  /// A translucent wash behind the token showing the reference speaker's pace
  /// (see `SpeechPace`); hidden while the word is playing so playback stays
  /// the strongest signal. `paceLabel` names the pace for assistive tech.
  var paceTint: Color? = nil
  var paceLabel: String? = nil
  var action: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false

  var body: some View {
    Group {
      if readOnly { tokenContent.accessibilityElement(children: .combine) }
      else { interactiveToken }
    }
  }

  private var tokenContent: some View {
      VStack(spacing: 4) {
        Text(word).font(
          EchoFont.body(size: (compact ? 25 : sentenceSize) * readingScale, weight: .medium)
        )
        .foregroundStyle(
          !enabled && !preservesReadingContrastWhenDisabled
            ? EchoTheme.disabledText : state == .playing ? EchoTheme.accent : EchoTheme.text)
        if showIPA && IPAFormatting.isPronounceable(word) {
          Group {
            if let ipa = IPAFormatting.display(ipa) {
              if let ipaFallbackLabel {
                Text(verbatim: "\(ipa) (\(ipaFallbackLabel))")
              } else {
                Text(verbatim: ipa)
              }
            } else {
              EchoLocalizedText("Chưa có IPA")
            }
          }.font(EchoFont.body(size: (compact ? 13 : ipaSize) * readingScale))
            .foregroundStyle(ipaTextColor)
        }
      }.fixedSize().padding(EchoMetrics.wordPadding)
        .frame(width: specimenWidth)
        .background {
          let shape = RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
          shape.fill(background)
          if let paceTint, state != .playing { shape.fill(paceTint) }
        }
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
  }

  private var interactiveToken: some View {
    Button(action: action) { tokenContent }
      .buttonStyle(ReadingTokenButtonStyle()).focused($focused).focusEffectDisabled()
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
  private var ipaTextColor: Color {
    if state == .playing { return EchoTheme.accent }
    // Dim the fallback pronunciation so it reads as an approximation.
    if ipaFallbackLabel != nil { return EchoTheme.disabledText }
    return EchoTheme.secondaryText
  }
  private var background: Color {
    if state == .playing { return EchoTheme.selection }
    if state == .selected || (hovered && enabled) { return EchoTheme.raised }
    return EchoTheme.surface
  }
  private var accessibilityStatus: String {
    let status: String = switch state {
    case .normal:
      IPAFormatting.isPronounceable(word) && IPAFormatting.display(ipa) == nil ? "Chưa có IPA" : ""
    case .selected: "Đã chọn"
    case .playing: "Đang nghe"
    case .needsTiming: "Cần chỉnh timing"
    }
    return [status, paceLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

private struct ReadingTokenButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    // Disabling playback must not dim the sentence the learner is reading aloud.
    configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
  }
}
