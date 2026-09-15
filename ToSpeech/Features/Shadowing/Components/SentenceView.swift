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
  var onPreviewLink: ((LinkingSuggestion, Double) -> Void)? = nil
  /// The sentences whose word timing sets the pace baseline (normally the whole
  /// lesson); a lone sentence is measured against itself.
  var paceContext: [LessonSentence]? = nil
  var onWord: (String) -> Void
  @State private var linking: [LinkingSuggestion] = []
  @State private var pace = SpeechPace.Analysis()
  @State private var openLinkID: String?
  @State private var linkSpeed = 0.75
  @FocusState private var focusedLinkID: String?
  private var textScale: CGFloat { readingScale * CGFloat(store.preferences.readingPercent) / 100 }
  var body: some View {
    let playingWordID = compact
      ? nil
      : runtime == nil ? store.practice.playingWordID(in: sentence) : runtime?.playingWordID
    let interactionDisabled = runtime?.interactionDisabled
      ?? (store.practice.phase.isCapture || store.practice.phase == .countdown || store.practice.phase == .saving
        || store.practice.phase == .saveFailed)
    VStack(alignment: .leading, spacing: 12) {
      if compact {
        headerLeading
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline) {
            headerLeading; Spacer(); HStack(spacing: 8) { sentenceOptions }
          }
          VStack(alignment: .leading, spacing: 8) {
            headerLeading
            WordFlowLayout(spacing: 8, lineSpacing: 8) { sentenceOptions }
          }
        }.tint(EchoTheme.text)
      }
      LinkingWordFlowLayout {
        ForEach(sentence.words) { word in
          wordToken(word, playingWordID: playingWordID, interactionDisabled: interactionDisabled)
          if let pause = pace.pause(after: word.id) {
            PauseMarker(duration: pause.duration, scale: textScale)
              .layoutValue(key: LinkingMarkerLayoutKey.self, value: true)
          }
          if let hint = linking.first(where: { $0.left.id == word.id }) {
            EchoLinkMarker(label: EchoLocalization.format("linking.open", locale: locale,
              arguments: [hint.left.text, hint.right.text]), scale: textScale,
              selected: openLinkID == hint.id) { openLinkID = hint.id }
              .focused($focusedLinkID, equals: hint.id)
              .layoutValue(key: LinkingMarkerLayoutKey.self, value: true)
              .popover(isPresented: Binding(get: { openLinkID == hint.id }, set: { if !$0 { openLinkID = nil } }), arrowEdge: .bottom) {
                LinkingSuggestionPopover(suggestion: hint,
                  canPlay: !interactionDisabled && hint.playbackSpan(in: sentence) != nil && onPreviewLink != nil,
                  timingNeedsReview: hint.left.needsTimingReview || hint.right.needsTimingReview,
                  speed: $linkSpeed,
                  onPlay: { if !interactionDisabled { onPreviewLink?(hint, linkSpeed) } },
                  onClose: { openLinkID = nil })
              }
          }
        }
      }
      if store.preferences.showTranslation {
        HStack(alignment: .top, spacing: 10) {
          // Placeholders are catalog keys; real translations fall back to themselves.
          EchoLocalizedText(
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
      if !linking.isEmpty {
        EchoLocalizedText("linking.legend").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
      if !compact, let take = runtime?.currentTake, let actions = runtime?.feedbackActions {
        InlineTakeFeedbackRow(take: take, onReview: actions.onReview, runtime: actions)
          .id("\(take.id)/\(sentence.revision)")
      } else if !compact, let onTakeReview {
        InlineTakeFeedback(sentence: sentence, onReview: onTakeReview)
          .id("\(store.selectedLessonID ?? "")/\(sentence.id)/\(sentence.revision)")
      }
    }.padding(20 * min(1.2, readingScale))
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
      .onChange(of: sentence, initial: true) { refreshLinking() }
      .onChange(of: store.preferences.accent) { refreshLinking() }
      .onChange(of: store.preferences.showLinking) { refreshLinking() }
      .onChange(of: sentence, initial: true) { refreshPace() }
      .onChange(of: store.preferences.accent) { refreshPace() }
      .onChange(of: store.preferences.showPace) { refreshPace() }
      .onChange(of: interactionDisabled) { if interactionDisabled { openLinkID = nil } }
      .onChange(of: openLinkID) { old, new in if new == nil { focusedLinkID = old } }
  }

  private var sentencePosition: some View {
Text(verbatim: EchoLocalization.format(
          "sentence.position", locale: locale,
          arguments: [sentence.number,
            runtime?.sentenceCount ?? store.selectedLesson?.sentences.count ?? 0]))
          .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
  }

  /// The sentence number shares its row with compact legend/hint chips; the full
  /// wording lives in each chip's tooltip so the header stays space-frugal.
  @ViewBuilder private var headerLeading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      sentencePosition
      if !pace.isEmpty { paceChip }
      if sentence.needsTimingReview { timingReviewChip }
      if showTapHint {
        annotationChip(
          symbol: "hand.tap", label: "hint.tap_word.short",
          tooltip: EchoLocalization.string("hint.tap_word", locale: locale), tint: EchoTheme.muted)
        if let word = sentence.words.first(where: { $0.id == selectedWordID }) {
          EchoButton(
            EchoLocalization.format("word.pronunciation_action", locale: locale, arguments: [word.text]),
            symbol: "speaker.wave.2", kind: .ghost
          ) { onWord(word.id) }
        }
      }
    }
  }

  /// The guidance only helps before a take exists; compact hosts hide it entirely.
  private var showTapHint: Bool {
    !compact
      && !(runtime?.hasCurrentTake ?? store.takes.contains(where: {
        $0.lessonID == store.selectedLessonID && $0.sentenceID == sentence.id
          && $0.sourceSnapshot.revision == sentence.revision && $0.scope == .sentence
      }))
  }

  private var paceChip: some View {
    HStack(spacing: 4) {
      Circle().fill(EchoTheme.paceFast).frame(width: 7, height: 7)
      Circle().fill(EchoTheme.paceSlow).frame(width: 7, height: 7)
      EchoLocalizedText("pace.short")
    }
    .font(EchoFont.body(size: 11, weight: .medium)).foregroundStyle(EchoTheme.secondaryText)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(EchoTheme.soft, in: Capsule())
    .contentShape(Capsule())
    .echoInfoTip { paceTooltip }
  }

  /// Legend tooltip that pairs each pace colour with its meaning, so the chip's
  /// bare dots are decipherable.
  private var paceTooltip: some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText("pace.legend")
        .fixedSize(horizontal: false, vertical: true)
      paceTooltipRow(EchoTheme.paceFast, "pace.legend.fast")
      paceTooltipRow(EchoTheme.paceSlow, "pace.legend.slow")
      if !pace.pauses.isEmpty {
        EchoLocalizedText("pace.legend.pause").foregroundStyle(EchoTheme.secondaryText)
      }
    }
    .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.text)
    .multilineTextAlignment(.leading)
    .frame(width: 220, alignment: .leading)
  }

  private func paceTooltipRow(_ color: Color, _ key: String) -> some View {
    HStack(spacing: 7) {
      Circle().fill(color).frame(width: 8, height: 8)
      EchoLocalizedText(key)
    }
  }

  private var timingReviewChip: some View {
    let unknown = sentence.words.contains { $0.span == nil }
    return annotationChip(
      symbol: "exclamationmark.triangle.fill", label: "timing.review.short",
      tooltip: EchoLocalization.string(
        unknown ? "Needs timing review · unknown words play in context" : "timing.observed.sentence_review",
        locale: locale),
      tint: EchoTheme.caution, background: EchoTheme.warning)
  }

  private func annotationChip(
    symbol: String, label: String, tooltip: String, tint: Color, background: Color = EchoTheme.soft
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
      EchoLocalizedText(label)
    }
    .font(EchoFont.body(size: 11, weight: .medium)).foregroundStyle(tint)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(background, in: Capsule())
    .contentShape(Capsule())
    .echoInfoTip(tooltip)
  }

  @ViewBuilder private var sentenceOptions: some View {
    @Bindable var store = store
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
            }.disabled(!store.preferences.usesTranslation)
            EchoButton(store.preferences.showLinking ? "linking.on" : "linking.off",
              surface: store.preferences.showLinking ? EchoTheme.selection : nil) {
              store.preferences.showLinking.toggle()
            }.accessibilityValue(EchoLocalization.string(
              store.preferences.showLinking ? "bật" : "tắt", locale: locale))
            EchoButton(store.preferences.showPace ? "pace.on" : "pace.off",
              surface: store.preferences.showPace ? EchoTheme.selection : nil) {
              store.preferences.showPace.toggle()
            }.accessibilityValue(EchoLocalization.string(
              store.preferences.showPace ? "bật" : "tắt", locale: locale))
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

  private func refreshLinking() {
    openLinkID = nil
    linking = store.preferences.showLinking
      ? LinkingSuggestions.suggestions(in: sentence, accent: store.preferences.accent) : []
  }

  /// Pace is relative to the whole lesson so a uniformly slow or fast sentence
  /// still reads as such; without that context (review snapshots, previews) the
  /// sentence is measured against its own median.
  private func refreshPace() {
    guard store.preferences.showPace else { pace = SpeechPace.Analysis(); return }
    let accent = store.preferences.accent
    let baseline = SpeechPace.baseline(in: paceContext ?? [], accent: accent)
      ?? SpeechPace.baseline(in: [sentence], accent: accent)
    pace = SpeechPace.analyze(sentence, accent: accent, baseline: baseline)
  }

  private func paceTint(for word: LessonWord) -> Color? {
    guard let pace = pace.words[word.id], pace.level != .even else { return nil }
    let colour = pace.level == .fast ? EchoTheme.paceFast : EchoTheme.paceSlow
    return colour.opacity(0.14 + 0.28 * pace.intensity)
  }

  private func paceLabel(for word: LessonWord) -> String? {
    guard let pace = pace.words[word.id], pace.level != .even else { return nil }
    return EchoLocalization.string(pace.level == .fast ? "pace.fast" : "pace.slow", locale: locale)
  }

  @ViewBuilder private func wordToken(_ word: LessonWord, playingWordID: String?, interactionDisabled: Bool) -> some View {
          let resolvedIPA = word.resolvedIPA(for: store.preferences.accent)
          EchoWordToken(
            word: word.text, ipa: resolvedIPA?.text,
            ipaFallbackLabel: resolvedIPA?.fallbackAccent?.rawValue,
            state: playingWordID == word.id
              ? .playing
              : selectedWordID == word.id
                ? .selected : word.span == nil || word.needsTimingReview ? .needsTiming : .normal,
            showIPA: store.preferences.showIPA, compact: compact, readingScale: textScale,
            sentenceSize: 34, ipaSize: 17,
            preservesReadingContrastWhenDisabled: true,
            paceTint: paceTint(for: word), paceLabel: paceLabel(for: word)
          ) { onWord(word.id) }.disabled(interactionDisabled)
          .accessibilityLabel(EchoLocalization.format(
            "word.open_pronunciation", locale: locale, arguments: [word.text])).help(
            word.span == nil ? "Hear in context · timing needs review" : "Hear original word")
  }
}

extension View {
  /// A web-style hover tooltip — a small styled bubble under the view — instead
  /// of the slow, system-chrome `.help()` tooltip.
  func echoInfoTip(_ text: String) -> some View {
    echoInfoTip {
      Text(text)
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.text)
        .multilineTextAlignment(.leading).lineSpacing(2)
        .frame(width: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Rich-content variant — e.g. a legend that pairs colour swatches with labels.
  func echoInfoTip<TipContent: View>(@ViewBuilder content: () -> TipContent) -> some View {
    modifier(EchoInfoTip(tip: content()))
  }
}

private struct EchoInfoTip<TipContent: View>: ViewModifier {
  let tip: TipContent
  @Environment(\.locale) private var locale
  @State private var show = false

  func body(content: Content) -> some View {
    content
      // A popover floats above the video and never clips; explicit content
      // widths stop the bubble from collapsing to the chip's narrow width.
      .onHover { show = $0 }
      .popover(isPresented: $show, arrowEdge: .bottom) {
        tip.padding(.horizontal, 12).padding(.vertical, 10).background(EchoTheme.raised)
          // The popover presents in a fresh environment that drops the app's
          // locale override, so EchoLocalizedText inside would fall back to the
          // base catalog (English). Re-inject the resolved locale.
          .environment(\.locale, locale)
      }
  }
}

/// A pause in the reference audio, placed between two words the way a linking
/// bridge is; the flow layout hides it when the words land on different lines.
private struct PauseMarker: View {
  var duration: Double
  var scale: CGFloat = 1
  @Environment(\.locale) private var locale

  var body: some View {
    let seconds = duration.formatted(.number.precision(.fractionLength(1)).locale(locale))
    VStack(spacing: 3 * scale) {
      Text(verbatim: "‖").font(EchoFont.body(size: 15 * scale, weight: .medium))
      Text(verbatim: seconds).font(EchoFont.body(size: 10 * scale))
    }
    .foregroundStyle(EchoTheme.secondaryText)
    .padding(.horizontal, 5 * scale)
    .frame(height: 48 * scale, alignment: .bottom)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(EchoLocalization.format("pace.pause", locale: locale, arguments: [seconds]))
    .help(EchoLocalization.format("pace.pause", locale: locale, arguments: [seconds]))
  }
}
