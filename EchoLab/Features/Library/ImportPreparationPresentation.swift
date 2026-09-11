import SwiftUI

enum ImportPreparationStepState: String, CaseIterable, Sendable {
  case completed
  case current
  case pending

  fileprivate var accessibilityKey: String {
    switch self {
    case .completed: "import.presentation.step.completed"
    case .current: "import.presentation.step.current"
    case .pending: "import.presentation.step.pending"
    }
  }
}

struct ImportPreparationStep: Identifiable, Equatable, Sendable {
  let id: String
  let title: EchoCopy
  let state: ImportPreparationStepState
}

/// Display-only progress supplied by the import coordinator.
/// This view does not infer checkpoints or advance progress on a timer.
struct ImportProgressPresentation: Equatable, Sendable {
  let currentTask: EchoCopy
  let currentStep: Int
  let totalSteps: Int
  let fractionCompleted: Double
  let steps: [ImportPreparationStep]
}

/// Display-only completion data supplied by the import coordinator.
/// The lesson title remains user content; formatted summaries stay localizable EchoCopy values.
struct ImportReadyPresentation: Equatable, Sendable {
  let lessonTitle: String
  let contentSummary: EchoCopy
  let practiceSummary: EchoCopy
}

enum ImportPreparationPresentation: Equatable, Sendable {
  case progress(ImportProgressPresentation)
  case ready(ImportReadyPresentation)
}

/// Stable UI seam for the import coordinator. All effects remain callback-owned by the caller.
struct ImportPreparationSheet: View {
  let presentation: ImportPreparationPresentation
  let onDismiss: () -> Void
  let onCancelImport: () -> Void
  let onStartPracticing: () -> Void

  @ViewBuilder var body: some View {
    switch presentation {
    case .progress(let value):
      ImportProgressSheet(
        presentation: value, onContinueBrowsing: onDismiss,
        onCancelImport: onCancelImport)
    case .ready(let value):
      ImportReadySheet(
        presentation: value, onStartPracticing: onStartPracticing,
        onBackToLibrary: onDismiss)
    }
  }
}

struct ImportProgressSheet: View {
  static let size = CGSize(width: 700, height: 520)

  let presentation: ImportProgressPresentation
  let onContinueBrowsing: () -> Void
  let onCancelImport: () -> Void

  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
          EchoLocalizedText("import.presentation.progress.eyebrow")
            .font(EchoFont.body(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(EchoTheme.secondaryText)
            .padding(.top, 5)
          Spacer()
          EchoIconButton(
            symbol: "xmark", label: "import.presentation.close",
            action: onContinueBrowsing)
        }

        EchoLocalizedText("import.presentation.progress.title")
          .font(EchoFont.heading(size: 24, weight: .semibold))
          .padding(.top, 14)

        EchoLocalizedText("import.presentation.progress.subtitle")
          .font(EchoFont.body(size: 13))
          .foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 7)

        HStack(alignment: .firstTextBaseline, spacing: 16) {
          EchoLocalizedText(presentation.currentTask)
            .font(EchoFont.body(size: 14, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 12)
          Text(verbatim: stepPosition)
            .font(EchoFont.body(size: 13, weight: .medium))
            .foregroundStyle(EchoTheme.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.top, 20)

        ImportProgressBar(fraction: presentation.fractionCompleted)
          .padding(.top, 12)

        VStack(alignment: .leading, spacing: 16) {
          ForEach(presentation.steps) { step in
            ImportPreparationStepRow(step: step)
          }
        }
        .padding(.top, 18)
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      ImportProgressFooter(
        onContinueBrowsing: onContinueBrowsing, onCancelImport: onCancelImport)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(EchoTheme.raised)
    .foregroundStyle(EchoTheme.text)
    .environment(\.echoControlSurface, EchoTheme.surface)
    .preferredColorScheme(.dark)
    .onExitCommand(perform: onContinueBrowsing)
  }

  private var stepPosition: String {
    EchoLocalization.format(
      "import.presentation.progress.position", locale: locale,
      arguments: [presentation.currentStep, presentation.totalSteps])
  }
}

struct ImportReadySheet: View {
  static let size = CGSize(width: 700, height: 440)

  let presentation: ImportReadyPresentation
  let onStartPracticing: () -> Void
  let onBackToLibrary: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
          ZStack {
            Circle().fill(EchoTheme.success)
            Image(systemName: "checkmark")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(EchoTheme.onAccent)
          }
          .frame(width: 52, height: 52)
          .accessibilityHidden(true)

          Spacer()
          EchoIconButton(
            symbol: "xmark", label: "import.presentation.close",
            action: onBackToLibrary)
        }

        EchoLocalizedText("import.presentation.ready.title")
          .font(EchoFont.heading(size: 24, weight: .semibold))
          .padding(.top, 14)

        Text(verbatim: presentation.lessonTitle)
          .font(EchoFont.body(size: 16, weight: .semibold))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 15)

        EchoLocalizedText(presentation.contentSummary)
          .font(EchoFont.body(size: 13))
          .foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)

        Divider().overlay(EchoTheme.border).padding(.top, 14)

        EchoLocalizedText(presentation.practiceSummary)
          .font(EchoFont.body(size: 14, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 13)

        EchoLocalizedText("import.presentation.ready.note")
          .font(EchoFont.body(size: 13))
          .foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      HStack(spacing: 12) {
        EchoButton(
          "import.presentation.ready.start", symbol: "arrow.right", kind: .primary,
          size: .regular, action: onStartPracticing)
        EchoButton(
          "import.presentation.ready.library", kind: .secondary, size: .regular,
          action: onBackToLibrary)
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .overlay(alignment: .top) { Divider().overlay(EchoTheme.border) }
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(EchoTheme.raised)
    .foregroundStyle(EchoTheme.text)
    .environment(\.echoControlSurface, EchoTheme.surface)
    .preferredColorScheme(.dark)
    .onExitCommand(perform: onBackToLibrary)
    .accessibilityElement(children: .contain)
    .echoAccessibilityLabel("import.presentation.ready.title")
  }
}

private struct ImportProgressFooter: View {
  let onContinueBrowsing: () -> Void
  let onCancelImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        EchoButton(
          "import.presentation.progress.continue", symbol: "arrow.left", kind: .primary,
          size: .regular, action: onContinueBrowsing)
        EchoButton(
          "import.presentation.progress.cancel", symbol: "xmark", kind: .secondary,
          size: .regular, action: onCancelImport)
        Spacer()
      }
      EchoLocalizedText("import.presentation.progress.background_note")
        .font(EchoFont.body(size: 12))
        .foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 18)
    .overlay(alignment: .top) { Divider().overlay(EchoTheme.border) }
  }
}

private struct ImportProgressBar: View {
  let fraction: Double

  private var clampedFraction: Double { min(1, max(0, fraction)) }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(EchoTheme.surface)
        Capsule().fill(EchoTheme.accent)
          .frame(width: proxy.size.width * clampedFraction)
      }
    }
    .frame(height: 6)
    .accessibilityElement(children: .ignore)
    .echoAccessibilityLabel("import.presentation.progress.accessibility")
    .accessibilityValue(Text(clampedFraction, format: .percent.precision(.fractionLength(0))))
  }
}

private struct ImportPreparationStepRow: View {
  let step: ImportPreparationStep

  var body: some View {
    HStack(spacing: 12) {
      ImportPreparationStepIndicator(state: step.state)
      EchoLocalizedText(step.title)
        .font(EchoFont.body(size: 13, weight: step.state == .current ? .semibold : .regular))
        .foregroundStyle(step.state == .pending ? EchoTheme.secondaryText : EchoTheme.text)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .echoAccessibilityValue(step.state.accessibilityKey)
  }
}

private struct ImportPreparationStepIndicator: View {
  let state: ImportPreparationStepState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var spinning = false

  var body: some View {
    Group {
      switch state {
      case .completed:
        Image(systemName: "checkmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(EchoTheme.success)
      case .current:
        ZStack {
          Circle().strokeBorder(EchoTheme.border, lineWidth: 1.5)
          Circle().trim(from: 0.08, to: 0.72)
            .stroke(EchoTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 270 : -90))
            .animation(
              reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
              value: spinning)
        }
        .onAppear { if !reduceMotion { spinning = true } }
      case .pending:
        Circle().strokeBorder(EchoTheme.border, lineWidth: 1.5)
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}
