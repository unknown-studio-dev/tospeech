import SwiftUI

struct ReviewSoundDetailView: View {
  @Environment(EchoStore.self) private var store
  var take: PracticeTake
  var priority: ReviewPriority
  var hasEvidence: Bool
  var onPracticePhrase: ([String]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Eyebrow("Word in context")
          Text(words).font(EchoFont.body(size: 17, weight: .semibold))
          Text(priority.phoneme).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
        }
        Spacer()
        EchoLocalizedText(priority.explanationCopy ?? EchoCopy(priority.explanation))
          .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
          .frame(
            maxWidth: 310, alignment: .leading)
      }
      HStack(spacing: 8) {
        EchoButton("Source sound", symbol: "speaker.wave.2") { preview("Source sound") }
        EchoButton("Recorded sound", symbol: "play") { preview("Recorded sound") }.disabled(
          !hasEvidence)
        EchoButton("Practise phrase", symbol: "repeat") { onPracticePhrase(priority.wordIDs) }
          .disabled(priority.wordIDs.isEmpty)
      }
      if !hasEvidence {
        Text("Recorded sound detail is unavailable for this take.").font(EchoFont.body(size: 11))
          .foregroundStyle(EchoTheme.muted)
      }
    }.padding(14).background(EchoTheme.soft, in: RoundedRectangle(cornerRadius: 10))
  }

  private var selectedWords: [LessonWord] {
    take.sourceSnapshot.words.filter { priority.wordIDs.contains($0.id) }
  }
  private var words: String { selectedWords.map(\.text).joined(separator: " ") }
  private func preview(_ label: String) {
    let spans = selectedWords.compactMap(\.span)
    let span =
      spans.isEmpty
      ? take.sourceSnapshot.span
      : AudioSpan(start: spans.map(\.start).min()!, end: spans.map(\.end).max()!)
    store.practice.previewSource(span: span, label: label)
  }
}

struct ReviewDeliveryDetailView: View {
  @Environment(\.locale) private var locale
  var assessment: AssessmentResult?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Pitch, stress & rhythm comparison").font(EchoFont.body(size: 13, weight: .semibold))
        Spacer()
        EchoBadge("Illustrative fixture · not measured", warning: true)
      }
      Text(
        "No validated native assessment pipeline currently supplies trustworthy delivery contours for this preview."
      )
      .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      HStack(spacing: 8) {
        dimension("Pitch")
        dimension("Stress")
        dimension("Rhythm")
      }
      if let assessment {
        Text(verbatim: EchoLocalization.format(
          "review.selected_result", locale: locale,
          arguments: [assessment.engine.title, assessment.version]))
          .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
      }
    }.padding(14).background(EchoTheme.soft, in: RoundedRectangle(cornerRadius: 10))
  }
  private func dimension(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      EchoLocalizedText(title).font(EchoFont.body(size: 10))
      Text("Unavailable").font(EchoFont.body(size: 11, weight: .semibold))
    }
    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(
      EchoTheme.raised, in: RoundedRectangle(cornerRadius: 7))
  }
}
