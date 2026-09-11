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
  @Environment(\.locale) private var locale
  @State private var draft: LessonSentence
  @State private var provenance: [LessonWord]
  @State private var scope: TimingScope
  @State private var selectedWordID: String?
  @State private var handle: TimingHandle = .start
  @State private var error: String?
  @State private var confirmingClose = false
  @State private var unalignedStart = ""
  @State private var unalignedEnd = ""
  @State private var isSaving = false

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
        Text(
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
    .sheet(isPresented: $confirmingClose) {
      EchoUnsavedSheet(
        onKeepEditing: { confirmingClose = false },
        onDiscard: { confirmingClose = false; onClose() },
        onSave: { confirmingClose = false; save(closeAfterSave: true) })
    }
  }

  private var sentenceEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      EchoTextField(label: "English transcript", text: transcriptBinding)
        .disabled(!allowsTranscriptEditing)
      DisclosureGroup("Edit transcript & translation") {
        field(title: "Vietnamese translation (optional)", text: $draft.translation)
          .disabled(!allowsTranslationEditing).padding(.top, 8)
      }.font(EchoFont.body(size: 11, weight: .medium)).foregroundStyle(EchoTheme.muted)
      waveform(
        span: draft.span,
        viewport: TimingRules.viewport(around: sentence.span, duration: lesson.duration),
        limits: AudioSpan(start: 0, end: lesson.duration)
      ) { next in
        if handle == .move,
          let shifted = TimingRules.shifted(
            draft, by: next.start - draft.span.start, duration: lesson.duration)
        {
          draft = shifted
        } else {
          draft.span = next
        }
      }
      timingControls(span: draft.span, bounds: AudioSpan(start: 0, end: lesson.duration)) { next in
        let delta = next.start - draft.span.start
        if handle == .move,
          let shifted = TimingRules.shifted(draft, by: delta, duration: lesson.duration)
        {
          draft = shifted
        } else {
          draft.span = next
        }
      }
    }
  }

  private var wordEditor: some View {
    VStack(alignment: .leading, spacing: 14) {
      Eyebrow("Choose a word")
      ScrollView(.horizontal) {
        HStack(spacing: 7) {
          ForEach(draft.words) { word in
            EchoButton(word.text, kind: selectedWordID == word.id ? .primary : .secondary) {
              selectedWordID = word.id
              unalignedStart = ""
              unalignedEnd = ""
            }
          }
        }
      }.scrollIndicators(.hidden)
      if let index = selectedWordIndex {
        let word = draft.words[index]
        if let span = word.span {
          waveform(span: span, viewport: draft.span, limits: wordBounds(at: index)) { next in
            updateWord(at: index, span: next)
          }
          timingControls(span: span, bounds: wordBounds(at: index)) { next in
            updateWord(at: index, span: next)
          }
          HStack {
            EchoButton("Preview word", symbol: "play.fill") {
              preview(span: word.span ?? draft.span, label: "Selected word")
            }
            EchoButton("Hear in sentence", symbol: "waveform") {
              preview(span: draft.span, label: "Sentence context")
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
    span: AudioSpan, bounds: AudioSpan, update: @escaping (AudioSpan) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        timeBox("Start", value: span.start) {
          applyNumeric($0, isStart: true, span: span, bounds: bounds, update: update)
        }
        timeBox("End", value: span.end) {
          applyNumeric($0, isStart: false, span: span, bounds: bounds, update: update)
        }
      }
      EchoSegmented(selection: $handle, options: TimingHandle.allCases.map {
        ($0, $0 == .move ? "Move whole sentence" : $0.rawValue)
      }).echoAccessibilityLabel("Timing adjustment handle")
      HStack(spacing: 12) {
        EchoButton("−100 ms") { nudge(-0.1, span: span, bounds: bounds, update: update) }
        EchoButton("+100 ms") { nudge(0.1, span: span, bounds: bounds, update: update) }
        EchoButton("Preview sentence", symbol: "play.fill") {
          preview(
            span: span, label: scope == .sentence ? "Sentence context" : "Selected word")
        }
      }
      Text(
        "Move shifts both boundaries and aligned words together. Start / End trims only that edge."
      )
      .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
    }
  }

  private func timeBox(_ title: String, value: Double, update: @escaping (Double) -> Void)
    -> some View
  {
    EchoNumberField(
      label: EchoLocalization.format(
        "timing.field_label", locale: locale,
        arguments: [
          EchoLocalization.string(scope == .sentence ? "Sentence" : "Word", locale: locale),
          EchoLocalization.string(title, locale: locale),
        ]),
      value: value, onCommit: update)
  }

  private var transcriptBinding: Binding<String> {
    Binding(
      get: { draft.text },
      set: { value in
        draft.text = value
        draft.words = TimingRules.reconcile(
          text: value, sentenceID: draft.id, candidates: provenance)
        for word in draft.words where !provenance.contains(where: { $0.id == word.id }) {
          provenance.append(word)
        }
      })
  }

  private func scopeButton(_ title: String, scope option: TimingScope) -> some View {
    EchoButton(title, kind: scope == option ? .primary : .secondary, size: .regular) {
      scope = option
    }.accessibilityAddTraits(scope == option ? .isSelected : [])
  }

  private func unalignedWordFields(index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Enter verified boundaries in seconds").font(EchoFont.body(size: 12)).foregroundStyle(
        EchoTheme.muted)
      HStack {
        EchoTextField(label: "Start", text: $unalignedStart).frame(width: 120)
        EchoTextField(label: "End", text: $unalignedEnd).frame(width: 120)
        EchoButton("Set timing") {
          guard let start = Double(unalignedStart), let end = Double(unalignedEnd) else {
            error = "Enter numeric start and end times."
            return
          }
          let span = AudioSpan(start: start, end: end)
          let bounds = wordBounds(at: index)
          guard start >= bounds.start, end <= bounds.end, end - start > TimingRules.minimumSpan
          else {
            error = "Word timing must be ordered inside its available sentence range."
            return
          }
          error = nil
          updateWord(at: index, span: span)
        }
      }
    }
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

  private func applyNumeric(
    _ value: Double, isStart: Bool, span: AudioSpan, bounds: AudioSpan, update: (AudioSpan) -> Void
  ) {
    let next: AudioSpan
    if handle == .move {
      guard let moved = TimingRules.moved(span, matchingStart: isStart, to: value, limits: bounds)
      else {
        error = "Moving this range would cross its available audio boundary."
        return
      }
      next = moved
    } else {
      next = AudioSpan(start: isStart ? value : span.start, end: isStart ? span.end : value)
    }
    guard next.start >= bounds.start, next.end <= bounds.end,
      next.duration > TimingRules.minimumSpan
    else {
      error = "Start must be before end and inside the available audio."
      return
    }
    error = nil
    update(next)
  }
  private func nudge(
    _ delta: Double, span: AudioSpan, bounds: AudioSpan, update: (AudioSpan) -> Void
  ) {
    let next: AudioSpan
    switch handle {
    case .start: next = AudioSpan(start: span.start + delta, end: span.end)
    case .end: next = AudioSpan(start: span.start, end: span.end + delta)
    case .move: next = AudioSpan(start: span.start + delta, end: span.end + delta)
    }
    guard next.start >= bounds.start, next.end <= bounds.end,
      next.duration > TimingRules.minimumSpan
    else { return }
    update(next)
  }
  private func reset() {
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
  private func requestClose() { if draft == sentence { onClose() } else { confirmingClose = true } }
  private func save(closeAfterSave: Bool = true) {
    if let validation = TimingRules.validate(draft, duration: lesson.duration) {
      error = validation
      return
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

  private func preview(span: AudioSpan, label: String) {
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
