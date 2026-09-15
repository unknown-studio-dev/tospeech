import SwiftUI

extension PronunciationQuality {
  var color: Color {
    switch self {
    case .correct: EchoTheme.success
    case .nearCorrect: EchoTheme.caution
    case .incorrect: EchoTheme.danger
    case .unassessed: EchoTheme.secondaryText
    }
  }
  var symbol: String {
    switch self {
    case .correct: "checkmark.circle"
    case .nearCorrect: "minus.circle"
    case .incorrect: "xmark.circle"
    case .unassessed: "questionmark.circle"
    }
  }
  var title: String { "review.quality.\(rawValue)" }
}

struct ReviewPhoneSelection: Hashable {
  let wordID: String
  let phoneID: Int
}

struct AssessedSentenceView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  let sentence: LessonSentence
  let evidence: PronunciationEvidence?
  let accent: ReferenceAccent
  let scale: CGFloat
  let selection: ReviewPhoneSelection?
  var onOpenLibrary: (() -> Void)? = nil
  var playingWordID: String? = nil
  let onSelect: (ReviewPhoneSelection) -> Void
  private var textScale: CGFloat { scale * CGFloat(store.preferences.readingPercent) / 100 }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ViewThatFits(in: .horizontal) {
        HStack { heading; Spacer(); legend; ReadingSizeControl() }
        VStack(alignment: .leading, spacing: 10) { heading; legend; ReadingSizeControl() }
      }
      WordFlowLayout(spacing: 16, lineSpacing: 16) {
        ForEach(sentence.words) { word in
          let assessed = evidence?.words.first { $0.id == word.id }
          let ipa = assessed?.referenceIPA ?? word.resolvedIPA(for: accent)?.text
          let runs = PronunciationDisplay.runs(ipa: ipa, word: assessed)
          VStack(spacing: 6) {
            Text(verbatim: word.text).font(EchoFont.body(size: 30*textScale, weight: .medium))
              .foregroundStyle(playingWordID == word.id ? EchoTheme.accent : EchoTheme.text)
            if !runs.isEmpty {
              HStack(spacing: 3) {
              EchoPhoneticText(runs: runs.map {
                EchoPhoneticRun(text: $0.text, color: $0.quality.color, linkID: $0.phoneID)
              }, size: 18*textScale) { onSelect(.init(wordID: word.id, phoneID: $0)) }
              .accessibilityLabel(accessibility(word: word, runs: runs))
              if !UKPhoneInventory.isUK(assessed?.inventory), let fallback = fallbackAccent(ipa, word: word) {
                Text(verbatim: "(\(fallback.rawValue))").font(EchoFont.body(size: 12*textScale))
                  .foregroundStyle(EchoTheme.secondaryText)
              }
              }
            } else if IPAFormatting.isPronounceable(word.text) {
              EchoLocalizedText("Chưa có IPA").font(EchoFont.body(size: 13*textScale)).foregroundStyle(EchoTheme.muted)
            }
          }
          .padding(.vertical, 4)
          .background(playingWordID == word.id || selection?.wordID == word.id ? EchoTheme.selection : .clear,
            in: RoundedRectangle(cornerRadius: 6))
          .overlay(alignment: .bottom) {
            if playingWordID == word.id {
              Capsule().fill(EchoTheme.accent).frame(height: 2).accessibilityHidden(true)
            }
          }
          .fixedSize()
          .id(word.id)
        }
      }
      if store.preferences.showTranslation, !sentence.translation.isEmpty {
        Text(verbatim: sentence.translation).font(EchoFont.body(size: 17*textScale))
          .foregroundStyle(EchoTheme.text).fixedSize(horizontal: false, vertical: true)
      }
      WordFlowLayout(spacing: 12, lineSpacing: 8) {
        EchoLocalizedText("review.ipa_hint").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        if let onOpenLibrary { EchoButton("coach.library", symbol: "book", kind: .ghost, action: onOpenLibrary) }
      }
    }
    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
  }
  private var heading: some View {
    Text(verbatim: EchoLocalization.format("review.sentence", locale: locale, arguments: [sentence.number]))
      .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
  }
  private var legend: some View {
    HStack(spacing: 12) {
      ForEach([PronunciationQuality.correct, .nearCorrect, .incorrect, .unassessed], id: \.self) { quality in
        Label(EchoLocalization.string(quality.title, locale: locale), systemImage: quality.symbol)
          .foregroundStyle(quality.color)
      }
      Text(verbatim: accent.rawValue).foregroundStyle(EchoTheme.secondaryText)
    }.font(EchoFont.body(size: 12))
  }
  private func accessibility(word: LessonWord, runs: [PronunciationDisplayRun]) -> String {
    word.text + ": " + runs.filter { $0.phoneID != nil }.map {
      "\($0.text): \(EchoLocalization.string($0.quality.title, locale: locale))"
    }.joined(separator: ", ")
  }
  private func fallbackAccent(_ ipa: String?, word: LessonWord) -> ReferenceAccent? {
    guard let ipa else { return nil }
    let other: ReferenceAccent = accent == .uk ? .us : .uk
    func phones(_ value: String?) -> [String]? { value.flatMap(PhoneInventory.parse)?.map(PhoneInventory.canonical) }
    guard let shown = phones(ipa), shown != phones(word.ipa(for: accent)), shown == phones(word.ipa(for: other)) else { return nil }
    return other
  }
}

/// Drawer-sized sentence context. The full sentence and every available IPA run
/// remain visible while the user moves between overview and detail pages.
struct CompactAssessedSentenceView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  let sentence: LessonSentence
  let evidence: PronunciationEvidence?
  let accent: ReferenceAccent
  let onSelect: (ReviewPhoneSelection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: sentence.text)
        .font(EchoFont.body(size: 15, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)

      WordFlowLayout(spacing: 9, lineSpacing: 8) {
        ForEach(sentence.words) { word in
          let assessed = evidence?.words.first { $0.id == word.id }
          let ipa = assessed?.referenceIPA ?? word.resolvedIPA(for: accent)?.text
          let runs = PronunciationDisplay.runs(ipa: ipa, word: assessed)
          if !runs.isEmpty {
            EchoPhoneticText(runs: runs.map {
              EchoPhoneticRun(text: $0.text, color: $0.quality.color, linkID: $0.phoneID)
            }, size: 13) {
              onSelect(.init(wordID: word.id, phoneID: $0))
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .accessibilityLabel(accessibility(word: word, runs: runs))
          }
        }
      }

      HStack(spacing: 10) {
        ForEach([PronunciationQuality.correct, .nearCorrect, .incorrect, .unassessed], id: \.self) { quality in
          Label(EchoLocalization.string(quality.title, locale: locale), systemImage: quality.symbol)
            .foregroundStyle(quality.color)
        }
      }
      .font(EchoFont.body(size: 10))
      .fixedSize(horizontal: false, vertical: true)

      if store.preferences.showTranslation, !sentence.translation.isEmpty {
        Text(verbatim: sentence.translation)
          .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(EchoTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
  }

  private func accessibility(word: LessonWord, runs: [PronunciationDisplayRun]) -> String {
    word.text + ": " + runs.filter { $0.phoneID != nil }.map {
      "\($0.text): \(EchoLocalization.string($0.quality.title, locale: locale))"
    }.joined(separator: ", ")
  }
}
