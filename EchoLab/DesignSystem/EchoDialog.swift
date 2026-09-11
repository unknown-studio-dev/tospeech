import SwiftUI

/// Native sheet content: a scrolling body and persistent action footer.
/// The caller owns dirty-draft confirmation and permission to dismiss.
struct EchoDialog<Content: View, Footer: View>: View {
  var title: String
  var subtitle: String
  var width: CGFloat = 560
  var height: CGFloat = 460
  var titleSize: CGFloat = 22
  var close: () -> Void
  @ViewBuilder var content: Content
  @ViewBuilder var footer: Footer

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          EchoLocalizedText(title).font(EchoFont.heading(size: titleSize, weight: .semibold))
          if !subtitle.isEmpty {
            EchoLocalizedText(subtitle).font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        EchoIconButton(symbol: "xmark", label: "Đóng", action: close)
      }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
      ScrollView {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
      }
      HStack { footer }.frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
    }.frame(width: width, height: height)
      .background(EchoTheme.raised).foregroundStyle(EchoTheme.text)
      .environment(\.echoControlSurface, EchoTheme.surface)
      .preferredColorScheme(.dark).onExitCommand(perform: close)
  }
}
