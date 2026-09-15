import SwiftUI

struct EchoBrandMark: View {
  var size: CGFloat = 32

  var body: some View {
    Image("ToSpeechToucan")
      .resizable()
      .renderingMode(.original)
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

struct EchoBrandLabel: View {
  var title: String = "ToSpeech"
  var size: CGFloat = 32
  var fontSize: CGFloat = 18

  var body: some View {
    HStack(spacing: 8) {
      EchoBrandMark(size: size)
      EchoLocalizedText(title)
        .font(EchoFont.body(size: fontSize, weight: .semibold))
        .foregroundStyle(EchoTheme.text)
        .lineLimit(1)
    }
  }
}
