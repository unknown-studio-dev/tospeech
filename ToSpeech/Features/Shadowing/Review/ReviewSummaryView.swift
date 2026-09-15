import SwiftUI

struct ReviewSummaryView: View {
  var take: PracticeTake
  var assessment: AssessmentResult
  var feedback: ReviewFeedback

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      EchoLocalizedText(
        take.scope == .phrase
          ? "Phrase-only fixture. Whole-sentence completeness is unavailable." : feedback.summary
      )
      .font(EchoFont.body(size: 13)).lineSpacing(3)
      HStack(alignment: .top, spacing: 14) {
        metric(
          "Completeness",
          take.scope == .phrase ? "Unavailable · phrase take" : feedback.completeness)
        metric("Fluency", feedback.fluency)
        metric("Delivery", "Details below")
      }
    }
    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      EchoLocalizedText(label).font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
      EchoLocalizedText(value).font(EchoFont.body(size: 11, weight: .semibold))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
