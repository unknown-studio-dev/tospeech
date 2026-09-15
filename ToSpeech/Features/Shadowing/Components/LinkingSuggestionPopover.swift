import SwiftUI

struct LinkingSuggestionPopover: View {
  var suggestion: LinkingSuggestion
  var canPlay: Bool
  var timingNeedsReview: Bool
  @Binding var speed: Double
  var onPlay: () -> Void
  var onClose: () -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        EchoLocalizedText("linking.title").font(EchoFont.body(size: 13, weight: .semibold))
          .foregroundStyle(EchoTheme.accent)
        Spacer()
        EchoIconButton(symbol: "xmark", label: "Close", surface: EchoTheme.raised, action: onClose)
      }
      Text(verbatim: suggestion.phrase).font(EchoFont.body(size: 28, weight: .medium))
      Text(verbatim: suggestion.pronunciation).font(EchoFont.body(size: 21)).foregroundStyle(EchoTheme.accent)
      Text(verbatim: EchoLocalization.format("linking.explanation", locale: locale,
        arguments: [suggestion.consonant, suggestion.left.text, suggestion.vowel, suggestion.right.text]))
        .font(EchoFont.body(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
      Divider().overlay(EchoTheme.separator)
      HStack(spacing: 8) {
        EchoButton("linking.play", symbol: "speaker.wave.2", kind: .primary, action: onPlay)
          .disabled(!canPlay)
        Spacer(minLength: 0)
        EchoSelect(label: "linking.speed", selection: Binding(
          get: { String(speed) }, set: { if let value = Double($0) { speed = value } }),
          options: PracticeOptions.speeds.map { (String($0), "\(EchoFormat.decimal($0))×") })
          .frame(width: 110)
      }
      if !canPlay {
        EchoLocalizedText("linking.play_unavailable").font(EchoFont.metadata).foregroundStyle(EchoTheme.caution)
      } else if timingNeedsReview {
        EchoLocalizedText("timing.observed.review").font(EchoFont.metadata).foregroundStyle(EchoTheme.caution)
      }
      EchoLocalizedText("linking.provenance").font(EchoFont.body(size: 12))
        .foregroundStyle(EchoTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
    }.padding(20).frame(width: 360).foregroundStyle(EchoTheme.text).background(EchoTheme.raised)
      .onExitCommand(perform: onClose)
  }
}
