import SwiftUI

struct UKDeliveryReviewView: View {
  let dimension: DeliveryDimension
  let evidence: UKReferenceEvidence
  let sourceOffset: Double
  let onCompare: (AudioSpan, AudioSpan) -> Void
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if dimension == .stress {
        if let words = evidence.stress, !words.isEmpty {
          EchoLocalizedText("assessment.uk.lexical_stress").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          ForEach(words) { word in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: word.text).font(EchoFont.body(size: 14, weight: .semibold))
                Text(verbatim: EchoLocalization.format("assessment.uk.syllable_comparison", locale: locale,
                  arguments: [word.sourceSyllable ?? 0, word.takeSyllable ?? 0]))
                  .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
              }
              Spacer()
              EchoIconButton(symbol: "headphones", label: "A → B") { compare(word.source, word.take) }
            }
          }
        }
        if !evidence.focus.isEmpty {
          EchoLocalizedText("assessment.uk.focus_model").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          ForEach(evidence.focus.sorted { abs($0.takeProbability-$0.sourceProbability) > abs($1.takeProbability-$1.sourceProbability) }) { word in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: word.text).font(EchoFont.body(size: 14, weight: .semibold))
                Text(verbatim: EchoLocalization.string(word.takeProbability > word.sourceProbability+0.2
                  ? "assessment.uk.more_focus" : word.takeProbability < word.sourceProbability-0.2
                  ? "assessment.uk.less_focus" : "assessment.uk.similar_focus", locale: locale))
                  .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
              }
              Spacer()
              EchoIconButton(symbol: "headphones", label: "A → B") { compare(word.source, word.take) }
            }
          }
        }
      }
      if dimension == .rhythm, let boundaries = evidence.boundaries, !boundaries.isEmpty {
        EchoLocalizedText("assessment.uk.boundary_model").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        ForEach(boundaries.sorted { abs($0.takeProbability-$0.sourceProbability) > abs($1.takeProbability-$1.sourceProbability) }) { word in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(verbatim: word.text).font(EchoFont.body(size: 14, weight: .semibold))
              EchoLocalizedText(word.takeProbability > word.sourceProbability+0.2 ? "assessment.uk.more_boundary"
                : word.takeProbability < word.sourceProbability-0.2 ? "assessment.uk.less_boundary" : "assessment.uk.similar_boundary")
                .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
            }
            Spacer()
            EchoIconButton(symbol: "headphones", label: "A → B") { compare(word.source, word.take) }
          }
        }
      }
      if dimension == .rhythm, !evidence.focus.isEmpty {
        EchoLocalizedText("assessment.uk.word_timing").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        ForEach(evidence.focus) { word in
          HStack {
            Text(verbatim: word.text).fontWeight(.semibold)
            Spacer()
            Text(verbatim: "\(EchoFormat.decimal(word.source.duration))s → \(EchoFormat.decimal(word.take.duration))s")
              .monospacedDigit()
            EchoIconButton(symbol: "headphones", label: "A → B") { compare(word.source, word.take) }
          }
        }
      }
      EchoLocalizedText(dimension == .stress ? "assessment.uk.stress_scope"
        : dimension == .intonation ? "assessment.uk.pitch_model" : "assessment.uk.delivery_scope")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
    }
  }
  private func compare(_ source: AudioSpan, _ take: AudioSpan) {
    onCompare(.init(start: source.start+sourceOffset, end: source.end+sourceOffset), take)
  }
}
