import SwiftUI

struct ProgressTakeRow: View {
  @Environment(\.locale) private var locale
  let take: PracticeTake
  let result: AssessmentResult?
  let open: () -> Void

  var body: some View {
    EchoRowButton(minimumHeight: 49, action: open) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: EchoLocalization.format(
            "progress.take_title", locale: locale,
            arguments: [take.number, take.sourceSnapshot.text]))
            .font(EchoFont.body(size: 12, weight: .medium)).lineLimit(1)
          Text(verbatim: EchoLocalization.format(
            "progress.take_metadata", locale: locale,
            arguments: [take.createdAt.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)),
              EchoLocalization.string(take.outcome.label, locale: locale),
              EchoLocalization.string(take.scope == .sentence ? "sentence" : "phrase", locale: locale)]))
          .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
        }
      Spacer()
      if let result {
        VStack(alignment: .trailing, spacing: 2) {
          Text(result.score.map(EchoFormat.decimal) ?? "—")
            .font(EchoFont.body(size: 17, weight: .semibold))
            .foregroundStyle(result.score == nil ? EchoTheme.muted : EchoTheme.success)
          Text("\(result.engine.title) · \(result.version)")
            .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
        }
      } else {
        EchoBadge(take.outcome == .noSpeech ? "No score · no speech" : "Not assessed")
      }
      }
    }
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay(RoundedRectangle(cornerRadius: 11).stroke(EchoTheme.line))
  }
}
