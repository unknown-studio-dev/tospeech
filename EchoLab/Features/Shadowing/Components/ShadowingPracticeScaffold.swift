import SwiftUI

/// The approved D02 screen composition. Feature routes supply content and
/// actions; they do not duplicate the media/sentence/review/transport layout.
struct ShadowingPracticeScaffold<
  Source: View, Transcript: View, Sentence: View, Review: View, Supplementary: View, Transport: View
>: View {
  let layout: ShadowingLayout
  let showsReview: Bool
  @ViewBuilder let source: () -> Source
  @ViewBuilder let transcript: () -> Transcript
  @ViewBuilder let sentence: () -> Sentence
  @ViewBuilder let review: () -> Review
  @ViewBuilder let supplementary: () -> Supplementary
  @ViewBuilder let transport: () -> Transport

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: ShadowingLayout.sectionGap) {
        if showsReview {
          review()
        } else {
          HStack(alignment: .top, spacing: ShadowingLayout.columnGap) {
            source().frame(width: layout.videoWidth)
            transcript().frame(width: layout.transcriptWidth, height: layout.mediaRowHeight)
          }
          sentence()
        }
        supplementary()
      }
    }
    .scrollIndicators(.visible)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !showsReview {
        transport()
          .padding(.top, ShadowingLayout.sectionGap)
          .background(EchoTheme.canvas)
      }
    }
  }
}
