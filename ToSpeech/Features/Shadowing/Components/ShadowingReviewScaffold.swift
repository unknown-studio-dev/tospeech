import SwiftUI

/// The approved D02c split review composition shared by preview and production.
struct ShadowingReviewScaffold<Source: View, Sentence: View, Panel: View>: View {
  let layout: ShadowingLayout
  let onBack: () -> Void
  @ViewBuilder let source: () -> Source
  @ViewBuilder let sentence: () -> Sentence
  @ViewBuilder let panel: () -> Panel

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      ScrollView {
        VStack(spacing: 20) {
          source().frame(width: layout.reviewSourceWidth)
          sentence()
          EchoButton("Back to practice", symbol: "arrow.left", action: onBack)
        }
      }.frame(width: layout.reviewSourceWidth)
      panel().frame(maxWidth: .infinity)
    }.frame(height: max(640, layout.contentHeight), alignment: .top)
  }
}
