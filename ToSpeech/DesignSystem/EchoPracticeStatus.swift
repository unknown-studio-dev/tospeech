import SwiftUI

struct EchoPracticeStatus: View {
  var title: String
  var detail: String
  var symbol: String
  var color: Color = EchoTheme.text
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        EchoLocalizedText(title)
      } icon: {
        Image(systemName: symbol)
      }.font(EchoFont.body(size: 14, weight: .semibold)).foregroundStyle(color)
      EchoLocalizedText(detail).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .combine)
  }
}

struct EchoContentSkeleton: View {
  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 10) {
        ForEach([380.0, 300.0, 180.0], id: \.self) { width in
          EchoSkeleton(height: 10).frame(width: min(width, max(0, geometry.size.width - 32)))
        }
      }.padding(16)
    }.frame(height: 82).background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .ignore).echoAccessibilityLabel("Đang tải nội dung")
  }
}
