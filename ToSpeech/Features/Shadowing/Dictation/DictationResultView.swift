import SwiftUI

struct DictationResultView: View {
  @Bindable var model: DictationModel
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale

  var body: some View {
    if let attempt = model.attempt {
      EchoPanel(padding: 20) {
      VStack(alignment: .leading, spacing: 16) {
        heading(attempt)
        counts(attempt)
        EchoLocalizedText(attempt.timedOut ? "dictation.expired" : "dictation.submitted")
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        EchoLocalizedText("dictation.your_answer").font(EchoFont.body(size: 14, weight: .semibold))
        Text(attempt.answer.isEmpty ? EchoLocalization.string("dictation.empty", locale: locale) : attempt.answer)
          .font(EchoFont.body(size: 18)).textSelection(.enabled)
        comparison(attempt)
        Divider().overlay(EchoTheme.border)
        EchoLocalizedText("dictation.reference").font(EchoFont.body(size: 14, weight: .semibold))
        reference
        HStack {
          EchoLocalizedText("dictation.text_only").font(EchoFont.metadata)
            .foregroundStyle(EchoTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
          Spacer()
          EchoButton("dictation.retry", symbol: "arrow.counterclockwise", action: model.retrySentence)
        }
      }.foregroundStyle(EchoTheme.text)
      }
    }
  }

  private func heading(_ attempt: DictationAttempt) -> some View {
    HStack {
      Text(EchoLocalization.format("dictation.match_count", locale: locale,
        arguments: [attempt.matchedCount, attempt.targetCount]))
        .font(EchoFont.heading(size: 22, weight: .semibold))
      Spacer()
      EchoSelect(label: "dictation.history", selection: Binding(
        get: { attempt.id.uuidString }, set: { model.selectedAttemptID = UUID(uuidString: $0) }),
        options: historyOptions).frame(width: 190)
    }
  }

  private var historyOptions: [(id: String, title: String)] {
    (model.current?.attempts ?? []).enumerated().map { index, item in
      (item.id.uuidString, EchoLocalization.format("dictation.attempt", locale: locale,
        arguments: [index + 1]) + " · "
        + item.submittedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
    }
  }

  private func counts(_ attempt: DictationAttempt) -> some View {
    HStack(spacing: 14) {
      status("checkmark.circle", "dictation.matched", EchoTheme.success, count: count(.matched, attempt))
      status("minus.circle", "dictation.missing", EchoTheme.caution, count: count(.missing, attempt))
      status("plus.circle", "dictation.extra", EchoTheme.danger, count: count(.extra, attempt))
      status("xmark.circle", "dictation.different", EchoTheme.danger, count: count(.different, attempt))
    }
  }

  private func comparison(_ attempt: DictationAttempt) -> some View {
        WordFlowLayout(spacing: 8, lineSpacing: 8) {
          ForEach(Array(attempt.comparison.words.enumerated()), id: \.offset) { _, word in
            comparisonWord(word)
          }
        }
  }

  private func comparisonWord(_ word: ContentMatch.Word) -> some View {
    let expected = word.expected ?? ""
    let observed = word.observed ?? ""
    let text = word.kind == .different ? observed + " → " + expected : word.expected ?? observed
    let label = EchoLocalization.string(key(word.kind), locale: locale) + ": " + text
    return EchoStatusBadge(title: text,
      tone: word.kind == .matched ? .success : word.kind == .missing ? .warning : .error,
      symbol: symbol(word.kind)).accessibilityLabel(label)
  }

  @ViewBuilder private var reference: some View {
        // The immutable revision used for this exercise also owns these annotations.
        if let sentence = model.sentence {
          WordFlowLayout(spacing: 14, lineSpacing: 14) {
            ForEach(sentence.tokens, id: \.id) { token in
              EchoWordToken(word: token.text, ipa: sentence.ipa(for: token, accent: store.preferences.accent),
                readOnly: true, action: {})
            }
          }
          if sentence.tokens.isEmpty { Text(sentence.target.text).font(EchoFont.body(size: 20)) }
          if let translation = sentence.translation {
            Text(translation).font(EchoFont.body(size: 15)).textSelection(.enabled)
          }
        }
  }

  private func count(_ kind: ContentMatch.Kind, _ attempt: DictationAttempt) -> Int {
    attempt.comparison.words.filter { $0.kind == kind }.count
  }
  private func status(_ symbol: String, _ key: String, _ tint: Color, count: Int) -> some View {
    HStack(spacing: 5) { Image(systemName: symbol); Text("\(count)"); EchoLocalizedText(key) }
      .font(EchoFont.metadata).foregroundStyle(tint)
  }
  private func key(_ kind: ContentMatch.Kind) -> String { "dictation.\(kind.rawValue)" }
  private func symbol(_ kind: ContentMatch.Kind) -> String {
    switch kind { case .matched: "checkmark.circle"; case .missing: "minus.circle"
    case .extra: "plus.circle"; case .different: "xmark.circle" }
  }
  private func color(_ kind: ContentMatch.Kind) -> Color {
    switch kind { case .matched: EchoTheme.success; case .missing: EchoTheme.caution
    case .extra, .different: EchoTheme.danger }
  }
}
