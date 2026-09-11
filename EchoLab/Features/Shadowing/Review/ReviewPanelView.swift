import SwiftUI

struct ReviewRuntimePresentation {
  var history: [PracticeTake]
  var selectedTakeID: String
  var onSelectTake: (String) -> Void
  var onPreviewOriginal: () -> Void
  var onPreviewTake: () -> Void
  var onCompare: () -> Void
  var assessmentUnavailableText: String?
}

struct ReviewPanelView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var take: PracticeTake
  var onRecordAgain: () -> Void
  var onPracticePhrase: ([String]) -> Void
  var runtime: ReviewRuntimePresentation? = nil
  @State private var selectedAssessmentID: String
  @State private var soundOpen = false
  @State private var deliveryOpen = false

  init(
    take: PracticeTake, onRecordAgain: @escaping () -> Void,
    onPracticePhrase: @escaping ([String]) -> Void,
    runtime: ReviewRuntimePresentation? = nil
  ) {
    self.take = take
    self.onRecordAgain = onRecordAgain
    self.onPracticePhrase = onPracticePhrase
    self.runtime = runtime
    _selectedAssessmentID = State(initialValue: take.assessments.last?.id ?? "")
  }

  var body: some View {
    EchoPanel(padding: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          Eyebrow(EchoLocalization.format(
            "review.recordings_sentence", locale: locale,
            arguments: [take.sourceSnapshot.number]))
          EchoLocalizedText(reviewTitle).font(EchoFont.heading(size: 20))
          Text(verbatim: EchoLocalization.format(
            "review.take_metadata", locale: locale,
            arguments: [take.number, selectedAssessment?.engine.title
              ?? EchoLocalization.string("Unscored", locale: locale),
              EchoLocalization.string(
                take.scope == .phrase ? "Phrase review" : "Whole-sentence review",
                locale: locale)]))
          .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
          takeHistory
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let assessment = selectedAssessment, assessment.status == .failed {
              failedAssessment(assessment)
            }
            if let assessment = completeAssessment {
              ReviewSummaryView(take: take, assessment: assessment, feedback: feedback)
            } else if selectedAssessment?.status != .failed {
              EchoNotice(
                text: statusTitle, error: take.outcome == .noSpeech || take.outcome == .quiet)
            }
            playback
            if completeAssessment != nil { priorities }
            if completeAssessment != nil {
              DisclosureGroup("Sounds & word detail", isExpanded: $soundOpen) {
                if let priority = feedback.priorities.first {
                  ReviewSoundDetailView(
                    take: take, priority: priority, hasEvidence: take.outcome == .complete,
                    onPracticePhrase: onPracticePhrase
                  ).padding(.top, 8)
                }
              }.tint(EchoTheme.muted).font(EchoFont.body(size: 13))
              DisclosureGroup("Pitch, stress & rhythm", isExpanded: $deliveryOpen) {
                ReviewDeliveryDetailView(assessment: selectedAssessment).padding(.top, 8)
              }.tint(EchoTheme.muted).font(EchoFont.body(size: 13))
            }
            if !take.assessments.isEmpty {
              DisclosureGroup("Engine details") { assessmentHistory.padding(.top, 8) }
                .tint(EchoTheme.muted).font(EchoFont.body(size: 11))
            }
          }
          .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .scrollIndicators(.automatic)
        Divider()
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            if let unavailable = runtime?.assessmentUnavailableText {
              Text(unavailable).font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
            } else {
              Text("Re-scoring appends a result and keeps this history.")
                .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
              if store.preferences.activeEngine == nil {
                EchoButton("Choose a model", kind: .ghost) { store.navigate(.settings) }
              } else {
                EchoButton("Re-score with active model", kind: .ghost) {
                  store.requestAssessment(takeID: take.id)
                }
                .disabled(!canRescore)
              }
            }
          }.foregroundStyle(EchoTheme.success)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { footerButtons }
            VStack(alignment: .leading, spacing: 8) { footerButtons }
          }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(EchoTheme.surface)
        .shadow(color: EchoTheme.canvas.opacity(0.24), radius: 8, y: -3)
      }.frame(maxHeight: .infinity)
    }
  }

  private var reviewTitle: String {
    guard completeAssessment != nil else { return statusTitle }
    if take.scope == .phrase { return "Focused phrase feedback." }
    if feedback.fluency == "One extra pause" { return "Clear overall. One pause to smooth out." }
    if feedback.fluency == "Even pacing" { return "Clear overall. Bring out the key words." }
    return "Review this sentence in context."
  }

  private var feedback: ReviewFeedback { ReviewFixtures.feedback(for: take.sourceSnapshot) }
  private var selectedAssessment: AssessmentResult? {
    take.assessments.first { $0.id == selectedAssessmentID } ?? take.assessments.last
  }
  private var completeAssessment: AssessmentResult? {
    if runtime != nil { return nil }
    return selectedAssessment?.status == .complete ? selectedAssessment : nil
  }
  private var hasPendingAssessment: Bool {
    take.assessments.contains { $0.status == .queued || $0.status == .running }
  }
  private var canRescore: Bool {
    guard [.complete, .earlyStop].contains(take.outcome), !hasPendingAssessment,
      let engine = store.preferences.activeEngine
    else { return false }
    return store.packages.contains { $0.id == engine && $0.status == .installed }
  }
  private var statusTitle: String {
    switch take.outcome {
    case .noSpeech: "No speech was detected. This is not a pronunciation score."
    case .quiet: "The saved voice was too quiet to assess reliably."
    case .earlyStop: "The take may have stopped before the sentence finished."
    case .interrupted: "This interrupted take was kept without a score."
    case .complete:
      hasPendingAssessment ? "Assessment is in progress. Your take is playable." : "Not assessed"
    }
  }

  @ViewBuilder private var takeHistory: some View {
    let matching = runtime?.history ?? store.takes.filter {
      $0.lessonID == take.lessonID && $0.sentenceID == take.sentenceID
    }
    if matching.count > 1 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(matching.sorted { $0.number < $1.number }) { item in
            EchoButton(EchoLocalization.format(
              "review.take", locale: locale, arguments: [item.number]),
              kind: item.id == (runtime?.selectedTakeID ?? store.reviewTakeID ?? take.id)
                ? .primary : .secondary) {
              let id = item.id
              if let runtime { runtime.onSelectTake(id) } else { store.reviewTakeID = id }
              selectedAssessmentID = matching.first { $0.id == id }?.assessments.last?.id ?? ""
            }
            .accessibilityLabel(EchoLocalization.format(
              "review.take", locale: locale, arguments: [item.number]))
              .accessibilityAddTraits(
                item.id == (runtime?.selectedTakeID ?? store.reviewTakeID ?? take.id)
                  ? .isSelected : [])
          }
        }
      }
      .accessibilityLabel("Saved recordings")
    }
  }

  @ViewBuilder private var assessmentHistory: some View {
    if !take.assessments.isEmpty {
      EchoSelect(
        label: "Assessment history", selection: $selectedAssessmentID,
        options: take.assessments.map { ($0.id, assessmentLabel($0)) })
      if let assessment = selectedAssessment {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { provenanceItems(assessment) }
          VStack(alignment: .leading, spacing: 8) { provenanceItems(assessment) }
        }
      }
    }
  }

  private var priorities: some View {
    VStack(alignment: .leading, spacing: 9) {
      Eyebrow("Priority corrections")
      ForEach(Array(feedback.priorities.prefix(2).enumerated()), id: \.element.id) { index, item in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: EchoLocalization.format(
              "review.priority", locale: locale,
              arguments: [String(format: "%02d", index + 1),
                item.titleCopy?.resolve(locale: locale)
                  ?? EchoLocalization.string(item.title, locale: locale)])).font(
              EchoFont.body(size: 13, weight: .semibold))
            EchoLocalizedText(item.explanationCopy ?? EchoCopy(item.explanation))
              .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
          }
          Spacer()
          EchoButton("Hear phrase") { previewPhrase(item) }
        }.padding(.horizontal, 14).frame(minHeight: 64)
          .background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  private var playback: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { playbackButtons }
      VStack(alignment: .leading, spacing: 8) { playbackButtons }
    }
  }

  @ViewBuilder private var playbackButtons: some View {
    EchoButton("Original sentence", symbol: "speaker.wave.2") {
      if let runtime { runtime.onPreviewOriginal() }
      else { store.practice.previewSource(span: take.sourceSnapshot.span, label: "Original sentence") }
    }
    EchoButton("Your full take", symbol: "play", kind: .primary) {
      if let runtime { runtime.onPreviewTake() }
      else {
        store.practice.previewSource(
          span: AudioSpan(start: 0, end: take.duration), label: "Saved take")
      }
    }
    EchoButton("A → B", symbol: "headphones") {
      if let runtime { runtime.onCompare() }
      else {
        store.practice.previewSource(
          span: AudioSpan(start: 0, end: take.duration), label: "A → B comparison")
      }
    }
  }

  @ViewBuilder private var footerButtons: some View {
    EchoButton(
      "Record sentence again", symbol: "arrow.counterclockwise", kind: .primary,
      action: onRecordAgain)
    EchoButton("Practise phrase", symbol: "repeat") {
      onPracticePhrase(feedback.priorities.first?.wordIDs ?? [])
    }
    .disabled(completeAssessment == nil || feedback.priorities.first?.wordIDs.isEmpty != false)
  }

  @ViewBuilder private func provenanceItems(_ assessment: AssessmentResult) -> some View {
    provenance("Engine", "\(assessment.engine.title) \(assessment.version)")
    provenance("Configuration", "\(assessment.accent.rawValue) · \(assessment.configuration)")
    provenance("Assessed", assessment.createdAt.formatted(date: .abbreviated, time: .shortened))
    provenance(
      "Score",
      assessment.score.map {
        EchoLocalization.format(
          "review.simulated_score", locale: locale, arguments: [Int($0.rounded())])
      } ?? EchoLocalization.string(assessment.status.titleKey, locale: locale))
  }

  private func provenance(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      EchoLocalizedText(title).font(EchoFont.body(size: 9)).foregroundStyle(EchoTheme.muted)
      Text(verbatim: value).font(EchoFont.body(size: 10, weight: .semibold)).lineLimit(2)
    }
    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(
      EchoTheme.soft, in: RoundedRectangle(cornerRadius: 8))
  }
  private func failedAssessment(_ assessment: AssessmentResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      EchoNotice(text: assessment.error ?? "Assessment failed. Your take is safe.", error: true)
      EchoButton("Retry assessment") {
        store.retryAssessment(takeID: take.id, assessmentID: assessment.id)
      }
    }
  }
  private func assessmentLabel(_ item: AssessmentResult) -> String {
    let status = item.score.map { String(Int($0.rounded())) }
      ?? EchoLocalization.string(item.status.titleKey, locale: locale)
    return "\(item.engine.title) \(item.version) · \(item.configuration) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(status)"
  }
  private func previewPhrase(_ priority: ReviewPriority) {
    let spans = take.sourceSnapshot.words.filter { priority.wordIDs.contains($0.id) }.compactMap(
      \.span)
    let span =
      spans.isEmpty
      ? take.sourceSnapshot.span
      : AudioSpan(start: spans.map(\.start).min()!, end: spans.map(\.end).max()!)
    store.practice.previewSource(span: span, label: "Hear phrase")
  }
}

private extension AssessmentStatus {
  var titleKey: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .complete: "Complete"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }
}
