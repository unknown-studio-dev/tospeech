import SwiftUI

enum InlineFeedbackState: Equatable {
  case pending, complete, failed, unscored, cancelled, noSpeech, quiet, earlyStop, interrupted

  init(take: PracticeTake) {
    switch take.outcome {
    case .noSpeech: self = .noSpeech
    case .quiet: self = .quiet
    case .interrupted: self = .interrupted
    case .complete, .earlyStop:
      switch take.latestAssessment?.status {
      case .queued, .running: self = .pending
      case .failed: self = .failed
      case .cancelled: self = .cancelled
      case .complete: self = take.outcome == .earlyStop ? .earlyStop : .complete
      case nil: self = take.outcome == .earlyStop ? .earlyStop : .unscored
      }
    }
  }
}

/// Keeps the currently visible result stable during countdown/capture, including late jobs.
struct InlineFeedbackPresentation {
  private(set) var take: PracticeTake?

  mutating func refresh(candidate: PracticeTake?, phase: PracticePhase) {
    guard !phase.isCapture, phase != .countdown else { return }
    take = candidate
  }

  static func latest(in takes: [PracticeTake], lessonID: String?, sentence: LessonSentence)
    -> PracticeTake?
  {
    takes.last {
      $0.lessonID == lessonID && $0.sentenceID == sentence.id
        && $0.sourceSnapshot.revision == sentence.revision && $0.scope == .sentence
    }
  }
}

struct InlineTakeFeedback: View {
  @Environment(EchoStore.self) private var store
  var sentence: LessonSentence
  var onReview: (PracticeTake) -> Void
  @State private var presentation = InlineFeedbackPresentation()

  private var candidate: PracticeTake? {
    InlineFeedbackPresentation.latest(
      in: store.takes, lessonID: store.selectedLessonID, sentence: sentence)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let take = presentation.take {
        InlineTakeFeedbackRow(take: take, onReview: { onReview(take) })
      }
    }
    .onAppear { refresh() }
    .onChange(of: candidate) { refresh() }
    .onChange(of: store.practice.phase) { refresh() }
  }

  private func refresh() { presentation.refresh(candidate: candidate, phase: store.practice.phase) }
}

struct InlineFeedbackRuntimeActions {
  var actionsBlocked: Bool
  var onCheckMicrophone: () -> Void
  var onCompare: () -> Void
  var onRetry: () -> Void
  var onReview: () -> Void
}

struct InlineTakeFeedbackRow: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var take: PracticeTake
  var onReview: () -> Void
  var runtime: InlineFeedbackRuntimeActions? = nil
  private var state: InlineFeedbackState { InlineFeedbackState(take: take) }
  private var actionsBlocked: Bool {
    runtime?.actionsBlocked
      ?? (store.practice.phase.isCapture
        || [.countdown, .saving, .saveFailed].contains(store.practice.phase))
  }

  var body: some View {
    VStack(spacing: 12) {
      Rectangle().fill(EchoTheme.border).frame(height: 1).accessibilityHidden(true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          summary
          Spacer(minLength: 16)
          actions
        }
        VStack(alignment: .leading, spacing: 12) {
          summary
          actions
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.top, 4)
    .transaction { $0.animation = nil }
  }

  private var summary: some View {
    HStack(spacing: 16) {
      Group {
        if state == .pending {
          EchoSpinner()
        } else {
          Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tone)
        }
      }.frame(width: 22, height: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: runtime == nil
          ? EchoLocalization.format(
            "take.inline.summary", locale: locale,
            arguments: [take.number, EchoLocalization.string(
              state == .complete ? "Nhận xét minh họa" : "Bản thu mô phỏng", locale: locale)])
          : "Take \(take.number) · Bản thu thật")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
        EchoLocalizedText(message).font(EchoFont.body(size: 17, weight: .medium))
          .foregroundStyle(EchoTheme.text).fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 8) {
      switch state {
      case .pending: EmptyView()
      case .noSpeech, .quiet:
        EchoButton("Kiểm tra mic", symbol: "mic", size: .regular) {
          if let runtime { runtime.onCheckMicrophone() }
          else {
            guard store.practice.interrupt() else { return }
            store.practice.permissionPresented = true
          }
        }
      case .failed:
        EchoButton("Thử lại", symbol: "arrow.clockwise", size: .regular) {
          if let runtime { runtime.onRetry() }
          else if let assessment = take.latestAssessment {
            store.retryAssessment(takeID: take.id, assessmentID: assessment.id)
          }
        }
      case .complete, .earlyStop, .interrupted, .unscored, .cancelled:
        EchoButton("Nghe A/B", symbol: "headphones", size: .regular) {
          if let runtime { runtime.onCompare() }
          else {
            store.practice.previewSource(
              span: take.sourceSnapshot.span, label: "A → B comparison")
            store.message = EchoCopy(
              "A/B đang mô phỏng giao diện; chưa phát audio gốc hay bản thu thật.")
          }
        }
        if runtime != nil {
          EchoButton("Xem bản thu", symbol: "arrow.up.right", size: .regular) {
            runtime?.onReview()
          }
        } else if state == .unscored || state == .cancelled {
          EchoButton("Chọn model", symbol: "slider.horizontal.3", size: .regular) {
            guard store.practice.interrupt() else { return }
            store.navigate(.settings)
          }
        } else {
          EchoButton("Xem chi tiết", symbol: "arrow.up.right", size: .regular, action: onReview)
        }
      }
    }.disabled(actionsBlocked)
  }

  private var message: String {
    switch state {
    case .pending: "Đang chấm câu này… Bạn vẫn có thể tiếp tục luyện."
    case .complete:
      runtime == nil
        ? ReviewFixtures.inlineSummary(for: take.sourceSnapshot)
        : "Bản thu đã được chấm. Mở review để xem chi tiết."
    case .failed: "Chưa chấm được. Bản thu vẫn được giữ; thử lại khi sẵn sàng."
    case .noSpeech: "Chưa nghe thấy giọng nói. Kiểm tra mic rồi thu lại."
    case .quiet: "Giọng quá nhỏ để chấm. Kiểm tra mic rồi thu lại."
    case .earlyStop: "Có thể câu bị ngắt sớm. Nghe lại bản thu trước khi luyện tiếp."
    case .interrupted: "Đã giữ lượt thu bị gián đoạn, không chấm điểm."
    case .unscored:
      runtime == nil
        ? "Bản thu đã lưu, chưa được chấm. Kiểm tra model trong Cài đặt."
        : "Bản thu đã lưu · chưa chấm."
    case .cancelled: "Đã hủy chấm; bản thu vẫn được giữ."
    }
  }
  private var symbol: String {
    switch state {
    case .complete: "checkmark.circle"
    case .failed: "exclamationmark.circle"
    case .noSpeech, .quiet: "mic.slash"
    case .earlyStop, .interrupted: "exclamationmark.triangle"
    default: "minus.circle"
    }
  }
  private var tone: Color {
    switch state {
    case .complete: EchoTheme.success
    case .failed: EchoTheme.danger
    case .noSpeech, .quiet, .earlyStop, .interrupted: EchoTheme.caution
    default: EchoTheme.secondaryText
    }
  }
}
