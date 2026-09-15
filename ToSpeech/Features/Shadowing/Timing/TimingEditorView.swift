import SwiftUI

private enum TimingScope: String, CaseIterable, Identifiable {
  case sentence = "Sentence timing"
  case word = "Word timing"
  var id: String { rawValue }
}

enum TimingHandle: String, CaseIterable, Identifiable {
  case start = "Start"
  case end = "End"
  case move = "Move"
  var id: String { rawValue }
}

struct TimingEditorView: View {
  let lesson: Lesson
  let sentence: LessonSentence
  let wordID: String?
  let onClose: () -> Void
  var onPreviewSource: ((AudioSpan, String) -> Void)? = nil
  var onSaveDraft: ((LessonSentence) async -> String?)? = nil
  var allowsTranscriptEditing = true
  var allowsTranslationEditing = true
  var waveformSamples: [Double]? = nil
  var usesSimulatedWaveform = true
  var isPreparingWaveform = false
  var waveformError: String? = nil
  var onRetryWaveform: (() -> Void)? = nil

  @Environment(EchoStore.self) private var store
  private var locale: Locale { store.preferences.language.locale }
  @State private var draft: LessonSentence
  @State private var provenance: [LessonWord]
  @State private var scope: TimingScope
  @State private var selectedWordID: String?
  @State private var handle: TimingHandle = .start
  @State private var error: String?
  @State private var confirmingClose = false
  @State private var isSaving = false
  @State private var numericDrafts = TimingInputDrafts()

  private var activeInputTarget: TimingInputTarget {
    scope == .word ? selectedWordID.map(TimingInputTarget.word) ?? .sentence : .sentence
  }

  private var numericInput: TimingNumericInput {
    get { numericDrafts[activeInputTarget] }
    nonmutating set { numericDrafts[activeInputTarget] = newValue }
  }

  init(
    lesson: Lesson, sentence: LessonSentence, wordID: String? = nil,
    onClose: @escaping () -> Void,
    onPreviewSource: ((AudioSpan, String) -> Void)? = nil,
    onSaveDraft: ((LessonSentence) async -> String?)? = nil,
    allowsTranscriptEditing: Bool = true,
    allowsTranslationEditing: Bool = true,
    waveformSamples: [Double]? = nil,
    usesSimulatedWaveform: Bool = true,
    isPreparingWaveform: Bool = false,
    waveformError: String? = nil,
    onRetryWaveform: (() -> Void)? = nil
  ) {
    self.lesson = lesson
    self.sentence = sentence
    self.wordID = wordID
    self.onClose = onClose
    self.onPreviewSource = onPreviewSource
    self.onSaveDraft = onSaveDraft
    self.allowsTranscriptEditing = allowsTranscriptEditing
    self.allowsTranslationEditing = allowsTranslationEditing
    self.waveformSamples = waveformSamples
    self.usesSimulatedWaveform = usesSimulatedWaveform
    self.isPreparingWaveform = isPreparingWaveform
    self.waveformError = waveformError
    self.onRetryWaveform = onRetryWaveform
    _draft = State(initialValue: sentence)
    _provenance = State(initialValue: sentence.words)
    let hasWord = wordID.flatMap { id in sentence.words.first { $0.id == id } } != nil
    _scope = State(initialValue: hasWord ? .word : .sentence)
    _selectedWordID = State(initialValue: hasWord ? wordID : sentence.words.first?.id)
  }

  var body: some View {
    EchoDialog(
      title: "Edit lesson timing",
      subtitle: "Fix a sentence that starts too early or ends too late. Preview before saving.",
      width: 720, height: 630, close: requestClose
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          scopeButton(EchoLocalization.format(
            "timing.sentence_scope", locale: locale,
            arguments: [sentence.number, lesson.sentences.count]), scope: .sentence)
          scopeButton("Word timing…", scope: .word)
        }

        if scope == .sentence { sentenceEditor } else { wordEditor }
        if let error { EchoNotice(copy: localizedError(error), error: true) }
        EchoLocalizedText(
          "Timing edits create a new revision. Existing takes keep their original timing snapshot."
        )
        .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
      }
    } footer: {
      HStack(spacing: 12) {
        EchoButton("Reset to original", action: reset)
        Spacer()
        EchoButton("Cancel", action: requestClose)
        EchoButton(
          "Save changes", symbol: "checkmark", kind: .primary,
          state: isSaving ? .loading("Saving") : .idle
        ) { save() }.disabled(isSaving)
      }
    }
    .environment(\.locale, store.preferences.language.locale)
    .sheet(isPresented: $confirmingClose) {
      EchoUnsavedSheet(
        onKeepEditing: { confirmingClose = false },
        onDiscard: { confirmingClose = false; onClose() },
        onSave: { confirmingClose = false; save(closeAfterSave: true) })
        .environment(\.locale, store.preferences.language.locale)
    }
  }

  private var sentenceEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      EchoTextField(label: "English transcript", text: transcriptBinding)
        .disabled(!allowsTranscriptEditing)
      if store.preferences.usesTranslation {
        EchoDisclosureGroup("Edit transcript & translation") {
          field(title: "Translation (optional)", text: $draft.translation)
            .disabled(!allowsTranslationEditing).padding(.top, 8)
        }.font(EchoFont.body(size: 11, weight: .medium)).foregroundStyle(EchoTheme.muted)
      }
      waveform(
        span: draft.span,
        viewport: TimingRules.viewport(around: sentence.span, duration: lesson.duration),
        limits: AudioSpan(start: 0, end: lesson.duration)
      ) { next in
        numericInput = TimingNumericInput()
        if handle == .move,
          let shifted = TimingRules.shifted(
            draft, by: next.start - draft.span.start, duration: lesson.duration)
        {
          draft = shifted
        } else {
          draft.span = next
        }
      }
      timingControls(span: draft.span, bounds: AudioSpan(start: 0, end: lesson.duration))
    }
  }

  private var wordEditor: some View {
    VStack(alignment: .leading, spacing: 14) {
      Eyebrow("Choose a word")
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 7) {
            ForEach(draft.words) { word in
              EchoButton(word.text, kind: selectedWordID == word.id ? .primary : .secondary) {
                guard selectedWordID != word.id else { return }
                _ = commitNumericInput(reportError: false)
                selectedWordID = word.id
                error = nil
              }.id(word.id)
            }
          }
        }.scrollIndicators(.hidden)
        .onChange(of: selectedWordID, initial: true) { _, id in
          if let id { proxy.scrollTo(id, anchor: .center) }
        }
      }
      Group {
        if let index = selectedWordIndex {
          let word = draft.words[index]
          if let span = word.span {
            waveform(span: span, viewport: draft.span, limits: wordBounds(at: index)) { next in
              numericInput = TimingNumericInput()
              updateWord(at: index, span: next)
            }
            timingControls(span: span, bounds: wordBounds(at: index))
            HStack {
              EchoButton("Preview word", symbol: "play.fill") {
                preview(sentenceContext: false)
              }
              EchoButton("Hear in sentence", symbol: "waveform") {
                preview(sentenceContext: true)
              }
            }
          } else {
            EchoNotice(copy: EchoCopy(
              "timing.unaligned_word", arguments: [.raw(word.text)]))
            unalignedWordFields(index: index)
          }
        } else {
          EchoNotice(text: "This sentence has no words to align.", error: true)
        }
      }.id(activeInputTarget)
    }
  }

  private func field(title: String, text: Binding<String>) -> some View {
    EchoTextField(label: title, text: text)
  }

  private func waveform(
    span: AudioSpan, viewport: AudioSpan, limits: AudioSpan, update: @escaping (AudioSpan) -> Void
  ) -> some View {
    TimingWaveform(
      span: span, viewport: viewport, limits: limits, selectedHandle: handle,
      samples: waveformSamples, sampleDomain: AudioSpan(start: 0, end: lesson.duration),
      usesSimulatedSamples: usesSimulatedWaveform, loading: isPreparingWaveform,
      loadError: waveformError, onRetry: onRetryWaveform, update: update
    )
    .frame(height: 74)
  }

  private func timingControls(
    span: AudioSpan, bounds: AudioSpan
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        timeBox("Start", value: span.start, isStart: true)
        timeBox("End", value: span.end, isStart: false)
      }
      EchoSegmented(selection: Binding(get: { handle }, set: { next in
        _ = commitNumericInput(reportError: false)
        handle = next
        error = nil
      }), options: TimingHandle.allCases.map {
        ($0, $0 == .move ? "Move whole sentence" : $0.rawValue)
      }).echoAccessibilityLabel("Timing adjustment handle")
      HStack(spacing: 12) {
        EchoButton("−100 ms") { nudge(-0.1, bounds: bounds) }
        EchoButton("+100 ms") { nudge(0.1, bounds: bounds) }
        EchoButton(scope == .sentence ? "Preview sentence" : "Preview word", symbol: "play.fill") {
          preview(sentenceContext: scope == .sentence)
        }
      }
      EchoLocalizedText(
        "Move shifts both boundaries and aligned words together. Start / End trims only that edge."
      )
      .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
    }
  }

  private func timeBox(_ title: String, value: Double, isStart: Bool)
    -> some View
  {
    let target = activeInputTarget
    return EchoTextField(
      label: EchoLocalization.format(
        "timing.field_label", locale: locale,
        arguments: [
          EchoLocalization.string(scope == .sentence ? "Sentence" : "Word", locale: locale),
          EchoLocalization.string(title, locale: locale),
        ]),
      text: Binding(
        get: {
          (isStart ? numericDrafts[target].start : numericDrafts[target].end)
            ?? value.formatted(.number.locale(locale).precision(.fractionLength(2)).grouping(.never))
        },
        set: {
          numericDrafts[target].edit($0, isStart: isStart)
          numericDrafts[target].movesRange = handle == .move
          error = nil
        }),
      helper: "Seconds")
      .onSubmit { _ = commitNumericInput() }
  }

  private var transcriptBinding: Binding<String> {
    Binding(
      get: { draft.text },
      set: { value in
        draft.text = value
        draft.words = TimingRules.reconcile(
          text: value, sentenceID: draft.id, candidates: provenance)
        numericDrafts.retainWords(Set(draft.words.map(\.id)))
        for word in draft.words where !provenance.contains(where: { $0.id == word.id }) {
          provenance.append(word)
        }
      })
  }

  private func scopeButton(_ title: String, scope option: TimingScope) -> some View {
    EchoButton(title, kind: scope == option ? .primary : .secondary, size: .regular) {
      guard scope != option else { return }
      _ = commitNumericInput(reportError: false)
      scope = option
      error = nil
    }.accessibilityAddTraits(scope == option ? .isSelected : [])
  }

  private func unalignedWordFields(index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      EchoLocalizedText("Enter verified boundaries in seconds").font(EchoFont.body(size: 12)).foregroundStyle(
        EchoTheme.muted)
      HStack {
        EchoTextField(label: "Start", text: unalignedBinding(index: index, isStart: true)).frame(width: 120)
        EchoTextField(label: "End", text: unalignedBinding(index: index, isStart: false)).frame(width: 120)
        EchoButton("Set timing") {
          _ = commitNumericInput()
        }
      }
    }
  }

  private func unalignedBinding(index: Int, isStart: Bool) -> Binding<String> {
    let target = TimingInputTarget.word(draft.words[index].id)
    return Binding(
      get: { (isStart ? numericDrafts[target].start : numericDrafts[target].end) ?? "" },
      set: {
        numericDrafts[target].edit($0, isStart: isStart)
        numericDrafts[target].movesRange = false
        error = nil
      })
  }

  private var selectedWordIndex: Int? {
    selectedWordID.flatMap { id in draft.words.firstIndex { $0.id == id } }
  }
  private func wordBounds(at index: Int) -> AudioSpan {
    let previous =
      draft.words[..<index].reversed().compactMap(\.span).first?.end ?? draft.span.start
    let next = draft.words.dropFirst(index + 1).compactMap(\.span).first?.start ?? draft.span.end
    return AudioSpan(start: previous, end: next)
  }
  private func updateWord(at index: Int, span: AudioSpan) {
    draft.words[index].span = span
    draft.words[index].needsTimingReview = false
    mergeProvenance(draft.words[index])
  }
  private func mergeProvenance(_ word: LessonWord) {
    if let index = provenance.firstIndex(where: { $0.id == word.id }) {
      provenance[index] = word
    } else {
      provenance.append(word)
    }
  }

  private var activeSpan: AudioSpan? {
    scope == .sentence ? draft.span : selectedWordIndex.flatMap { draft.words[$0].span }
  }

  private func applyRange(_ span: AudioSpan, moving: Bool? = nil) {
    if scope == .word, let index = selectedWordIndex {
      updateWord(at: index, span: span)
    } else if moving ?? (handle == .move),
      let shifted = TimingRules.shifted(draft, by: span.start - draft.span.start, duration: lesson.duration) {
      draft = shifted
    } else {
      draft.span = span
    }
    numericInput = TimingNumericInput()
  }

  private func commitNumericInput(reportError: Bool = true) -> Bool {
    guard numericInput.isDirty else { return true }
    if activeSpan == nil && (numericInput.start == nil || numericInput.end == nil) {
      if reportError { error = "Enter numeric start and end times." }
      return false
    }
    let span = activeSpan ?? draft.span
    let bounds: AudioSpan
    if scope == .word, let index = selectedWordIndex { bounds = wordBounds(at: index) }
    else { bounds = AudioSpan(start: 0, end: lesson.duration) }
    let moving = numericInput.movesRange && activeSpan != nil
    guard let next = numericInput.resolve(span: span, bounds: bounds, moving: moving, locale: locale) else {
      if reportError { error = "Start must be before end and inside the available audio." }
      return false
    }
    error = nil
    applyRange(next, moving: moving)
    return true
  }
  private func nudge(
    _ delta: Double, bounds: AudioSpan
  ) {
    guard commitNumericInput(), let span = activeSpan else { return }
    let next: AudioSpan
    switch handle {
    case .start: next = AudioSpan(start: span.start + delta, end: span.end)
    case .end: next = AudioSpan(start: span.start, end: span.end + delta)
    case .move: next = AudioSpan(start: span.start + delta, end: span.end + delta)
    }
    guard next.start >= bounds.start, next.end <= bounds.end,
      next.duration > TimingRules.minimumSpan
    else { return }
    applyRange(next)
  }
  private func reset() {
    numericDrafts = TimingInputDrafts()
    if let baseline = sentence.baseline {
      draft.text = baseline.text
      draft.translation = baseline.translation
      draft.span = baseline.span
      draft.words = baseline.words
    } else {
      draft = sentence
    }
    provenance = draft.words
    selectedWordID = wordID ?? draft.words.first?.id
    error = nil
  }
  private func requestClose() {
    if draft == sentence && !numericDrafts.isDirty { onClose() } else { confirmingClose = true }
  }
  private func save(closeAfterSave: Bool = true) {
    switch numericDrafts.applying(to: draft, duration: lesson.duration, locale: locale) {
    case .failure(let failure):
      switch failure.target {
      case .sentence: scope = .sentence
      case .word(let id): scope = .word; selectedWordID = id
      }
      error = failure.message
      return
    case .success(let resolved):
      draft = resolved
      numericDrafts = TimingInputDrafts()
      for word in draft.words { mergeProvenance(word) }
      error = nil
    }
    if let onSaveDraft {
      isSaving = true
      Task {
        let failure = await onSaveDraft(draft)
        isSaving = false
        if let failure { error = failure }
        else if closeAfterSave { onClose() }
      }
    } else {
      if let failure = store.saveSentence(
        draft, lessonID: lesson.id, expectedRevision: sentence.revision)
      {
        error = failure
        return
      }
      if closeAfterSave { onClose() }
    }
  }

  private func preview(sentenceContext: Bool) {
    guard commitNumericInput(), let span = sentenceContext ? draft.span : activeSpan else { return }
    let label = sentenceContext ? "Sentence context" : "Selected word"
    if let onPreviewSource { onPreviewSource(span, label) }
    else { store.practice.previewSource(span: span, label: label) }
  }

  private func localizedError(_ value: String) -> EchoCopy {
    let prefix = "Timing for "
    let suffix = " must stay inside the sentence."
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return EchoCopy(value) }
    let start = value.index(value.startIndex, offsetBy: prefix.count)
    let end = value.index(value.endIndex, offsetBy: -suffix.count)
    return EchoCopy(
      "timing.word_inside_sentence", arguments: [.raw(String(value[start..<end]))])
  }
}
