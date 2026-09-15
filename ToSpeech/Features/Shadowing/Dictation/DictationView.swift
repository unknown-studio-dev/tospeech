import SwiftUI

struct DictationView: View {
  @Bindable var model: DictationModel
  let layout: ShadowingLayout
  let lesson: Lesson
  var thumbnailURL: URL?
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale

  var body: some View {
    ShadowingPracticeScaffold(layout: layout, showsReview: false,
      source: {
        VideoPreviewView(lesson: lesson, onEdit: {}, isProductionMode: true,
          productionThumbnailURL: thumbnailURL, concealsVideo: true)
      }, transcript: { navigator }, sentence: {
        Group {
          if model.isLoading { EchoLoading(title: "dictation.loading") }
          else if model.current != nil {
            if model.phase == .result { DictationResultView(model: model) }
            else { answer }
          }
        }.echoContentReveal(value: [model.isLoading, model.phase == .result], enabled: !model.isPlaying)
      }, review: { EmptyView() }, supplementary: {
        if let error = model.loadError {
          HStack {
            EchoNotice(copy: EchoCopy("storage.detail", arguments: [.raw(error)]), error: true)
            EchoButton("Retry") { Task { await model.reload() } }
          }
        }
        if let error = model.error {
          EchoNotice(copy: EchoCopy("storage.detail", arguments: [.raw(error)]), error: true)
        }
        if let error = model.saveError {
          HStack {
            EchoNotice(copy: EchoCopy("dictation.save_error", arguments: [.raw(error)]), error: true)
            EchoButton("Retry", action: model.retrySave)
          }
        }
      }, transport: { transport })
  }

  private var navigator: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        EchoLocalizedText("dictation.title").font(EchoFont.body(size: 15, weight: .semibold))
        Spacer()
        Text("\(model.completedCount) / \(model.sentences.count)")
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.accent)
          .echoAccessibilityLabel("dictation.completed")
      }
      HStack(spacing: 8) {
        EchoSegmented(selection: Binding(get: { model.displayedTimeLimit != nil }, set: {
          model.setLimit($0 ? model.lastTimedLimit : nil)
        }), options: [(false, "dictation.free"), (true, "dictation.timed")])
        if let limit = model.displayedTimeLimit {
          EchoSelect(label: "dictation.limit", selection: Binding(
            get: { String(limit) }, set: { model.setLimit(Int($0)) }),
            options: DictationProgress.timeLimits.map { (String($0), "\($0) s") })
            .frame(width: 104)
        }
      }.disabled(!model.canChangeLimit)
      if !model.canChangeLimit {
        EchoLocalizedText("dictation.limit_locked").font(EchoFont.metadata).foregroundStyle(EchoTheme.muted)
      }
      GeometryReader { proxy in
        Capsule().fill(EchoTheme.border).overlay(alignment: .leading) {
          Capsule().fill(EchoTheme.accent)
            .frame(width: proxy.size.width * Double(model.completedCount) / Double(max(1, model.sentences.count)))
        }
      }.frame(height: 3).accessibilityHidden(true)
      TranscriptNavigatorView(lesson: lesson, selectedSentenceID: model.selectedID?.uuidString,
        onSelectSentence: { if let id = UUID(uuidString: $0) { model.selectAndListen(id) } },
        concealedStatus: { rowStatus(UUID(uuidString: $0) ?? UUID()) })
      EchoLocalizedText(model.phase == .result ? "dictation.result_hint" : "dictation.answers_hidden").font(EchoFont.metadata).foregroundStyle(EchoTheme.muted)
    }.foregroundStyle(EchoTheme.text)
  }

  private func rowStatus(_ id: UUID) -> String {
    guard let value = model.progress[id] else { return "dictation.not_started" }
    if id == model.selectedID && !value.draft.submitted { return phaseKey }
    if let attempt = value.latest {
      return EchoLocalization.format("dictation.match_count", locale: locale,
        arguments: [attempt.matchedCount, attempt.targetCount])
    }
    return value.draft.hasListened ? "dictation.draft" : "dictation.not_started"
  }

  private var answer: some View {
    EchoPanel(padding: 20) {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 20) {
        DictationStatusView(model: model).frame(width: 186)
        editor.frame(minWidth: 400, maxWidth: .infinity)
      }
      VStack(alignment: .leading, spacing: 16) { DictationStatusView(model: model); editor }
    }
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        EchoLocalizedText("dictation.prompt").font(EchoFont.body(size: 15, weight: .semibold))
        Spacer()
        Text("⌘↵").font(EchoFont.metadata).foregroundStyle(EchoTheme.muted)
      }
      EchoTextEditor(label: "dictation.prompt", text: Binding(
        get: { model.current?.draft.answer ?? "" }, set: { model.edit($0) }),
        placeholder: model.phase == .paused ? "dictation.resume_hint" : model.canEdit ? "dictation.placeholder" : "dictation.listen_first",
        // Focus returns to the editor after every replay, so ⌘R or the play
        // button never leaves the learner clicking back into the field.
        editable: model.canEdit,
        focusID: "\(model.selectedID?.uuidString ?? "")/\(model.current?.draft.listenCount ?? 0)")
      HStack {
        Text("\(ContentMatch.tokens(model.current?.draft.answer ?? "").count)")
        EchoLocalizedText("dictation.words")
        Text("·")
        EchoLocalizedText(model.saveError != nil ? "dictation.unsaved" : model.isSaving ? "dictation.saving" : "dictation.saved")
        Spacer(minLength: 8)
        EchoButton("dictation.submit", kind: .primary, size: .regular) { model.submit() }
          .keyboardShortcut(.return, modifiers: .command).disabled(!model.canEdit)
      }.font(EchoFont.metadata).foregroundStyle(EchoTheme.muted)
    }
  }

  private var transport: some View {
    PracticeTransportView(onOptions: {}, onReview: {}, compact: layout.contentWidth < 850,
      dictationModel: model)
  }

  private var phaseKey: String { model.phaseKey }
}

/// The countdown and phase label. It is the only part of the screen that reads
/// the ticking clock, so ten updates a second redraw this ring and nothing else.
private struct DictationStatusView: View {
  var model: DictationModel
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(EchoLocalization.format("dictation.sentence_number", locale: locale,
        arguments: [(model.sentences.firstIndex { $0.id == model.selectedID } ?? 0) + 1, model.sentences.count]))
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      HStack(spacing: 12) {
        ZStack {
          Circle().stroke(EchoTheme.border, lineWidth: 3)
          Circle().trim(from: 0, to: timerFraction)
            .stroke(EchoTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Text(model.remainingSeconds.map { String(Int(ceil($0))) } ?? "∞")
            .font(EchoFont.heading(size: 24, weight: .semibold)).monospacedDigit()
        }.frame(width: 60, height: 60)
          .accessibilityLabel(EchoLocalization.string("dictation.time_remaining", locale: locale))
          .accessibilityValue(model.remainingSeconds.map { String(Int(ceil($0))) } ?? EchoLocalization.string("dictation.free", locale: locale))
        EchoLocalizedText(model.phaseKey).font(EchoFont.body(size: 14, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
      }
      EchoLocalizedText(model.remainingSeconds == nil ? "dictation.free_hint" : model.current?.draft.hasListened == true ? "dictation.expiry_hint" : "dictation.timer_hint")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var timerFraction: Double {
    guard let limit = model.current?.draft.timeLimit, let remaining = model.remainingSeconds else { return 1 }
    return max(0, min(1, remaining / Double(limit)))
  }
}
