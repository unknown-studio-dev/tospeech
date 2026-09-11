import SwiftUI

struct SentenceRuntimePresentation {
  var playingWordID: String?
  var interactionDisabled: Bool
  var hasCurrentTake: Bool
  var takeCount: Int = 0
  var sentenceCount: Int? = nil
  var translationPlaceholder: String? = nil
  var currentTake: PracticeTake? = nil
  var feedbackActions: InlineFeedbackRuntimeActions? = nil
}

struct SentenceView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var sentence: LessonSentence
  @Binding var selectedWordID: String?
  var compact = false
  var readingScale: CGFloat = 1
  var onReview: (() -> Void)? = nil
  var onTakeReview: ((PracticeTake) -> Void)? = nil
  var runtime: SentenceRuntimePresentation? = nil
  var onWord: (String) -> Void
  private var textScale: CGFloat { readingScale * CGFloat(store.preferences.readingPercent) / 100 }
  var body: some View {
    @Bindable var store = store
    let playingWordID = compact
      ? nil
      : runtime == nil ? store.practice.playingWordID(in: sentence) : runtime?.playingWordID
    let interactionDisabled = runtime?.interactionDisabled
      ?? (store.practice.phase.isCapture || store.practice.phase == .saving
        || store.practice.phase == .saveFailed)
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: EchoLocalization.format(
          "sentence.position", locale: locale,
          arguments: [sentence.number,
            runtime?.sentenceCount ?? store.selectedLesson?.sentences.count ?? 0]))
          .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
        Spacer()
        if !compact {
          HStack(spacing: 8) {
            ReadingSizeControl()
            EchoSelect(
              label: "Giọng tham khảo",
              selection: Binding(
                get: { store.preferences.accent.rawValue },
                set: {
                  if let accent = ReferenceAccent(rawValue: $0) {
                    store.preferences.accent = accent
                  }
                }),
              options: ReferenceAccent.allCases.map { ($0.rawValue, $0.rawValue) }
            ).frame(width: 78)
            EchoButton(EchoLocalization.format(
              "sentence.ipa_toggle", locale: locale,
              arguments: [EchoLocalization.string(store.preferences.showIPA ? "bật" : "tắt", locale: locale)])) {
              store.preferences.showIPA.toggle()
            }
            EchoButton(EchoLocalization.format(
              "sentence.translation_toggle", locale: locale,
              arguments: [EchoLocalization.string(store.preferences.showTranslation ? "bật" : "tắt", locale: locale)])) {
              store.preferences.showTranslation.toggle()
            }
            if let onReview {
              EchoButton(
                EchoLocalization.format(
                  "sentence.takes", locale: locale,
                  arguments: [runtime?.takeCount ?? store.takes.filter { $0.sentenceID == sentence.id }.count]),
                symbol: "waveform", action: onReview
              )
              .disabled(
                !(runtime.map { $0.takeCount > 0 }
                  ?? store.takes.contains { $0.sentenceID == sentence.id }))
            }
          }
        }
      }.frame(height: 32).tint(EchoTheme.text)
      WordFlowLayout(spacing: 0, lineSpacing: 12) {
        ForEach(sentence.words) { word in
          EchoWordToken(
            word: word.text, ipa: word.ipa(for: store.preferences.accent),
            state: playingWordID == word.id
              ? .playing
              : selectedWordID == word.id
                ? .selected : word.span == nil || word.needsTimingReview ? .needsTiming : .normal,
            showIPA: store.preferences.showIPA, compact: compact, readingScale: textScale,
            sentenceSize: 34, ipaSize: 17,
            preservesReadingContrastWhenDisabled: true
          ) { onWord(word.id) }.disabled(interactionDisabled)
          .accessibilityLabel(EchoLocalization.format(
            "word.open_pronunciation", locale: locale, arguments: [word.text])).help(
            word.span == nil ? "Hear in context · timing needs review" : "Hear original word")
        }
      }
      if store.preferences.showTranslation {
        HStack(alignment: .top, spacing: 10) {
          Text(
            sentence.translation.isEmpty
              ? runtime?.translationPlaceholder
                ?? "Translation unavailable · edit this sentence to add one." : sentence.translation
          )
          .font(EchoFont.body(size: (compact ? 14 : 17) * textScale)).foregroundStyle(
            EchoTheme.text
          )
          .lineSpacing(4)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        }
      }
      if sentence.needsTimingReview {
        EchoBadge("Needs timing review · unknown words play in context", warning: true)
      }
      if !compact, let take = runtime?.currentTake, let actions = runtime?.feedbackActions {
        InlineTakeFeedbackRow(take: take, onReview: actions.onReview, runtime: actions)
          .id("\(take.id)/\(sentence.revision)")
      } else if !compact, let onTakeReview {
        InlineTakeFeedback(sentence: sentence, onReview: onTakeReview)
          .id("\(store.selectedLessonID ?? "")/\(sentence.id)/\(sentence.revision)")
      }
      if !compact
        && !(runtime?.hasCurrentTake ?? store.takes.contains(where: {
          $0.lessonID == store.selectedLessonID && $0.sentenceID == sentence.id
            && $0.sourceSnapshot.revision == sentence.revision && $0.scope == .sentence
        }))
      {
        HStack {
          Text("Bấm một từ để nghe giọng gốc và xem phát âm.").font(EchoFont.body(size: 12))
            .foregroundStyle(EchoTheme.muted)
          Spacer()
          if let word = sentence.words.first(where: { $0.id == selectedWordID }) {
            EchoButton(EchoLocalization.format(
              "word.pronunciation_action", locale: locale, arguments: [word.text]),
              symbol: "speaker.wave.2", kind: .ghost) {
              onWord(word.id)
            }
          }
        }
      }
    }.padding(20 * min(1.2, readingScale))
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
  }
}
