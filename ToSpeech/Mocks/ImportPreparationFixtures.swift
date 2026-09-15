import Foundation

/// Visual fixtures only. They are not connected to production import checkpoints.
enum ImportPreparationFixtures {
  static let progress = ImportProgressPresentation(
    currentTask: EchoCopy("import.presentation.progress.task.transcript_timing"),
    currentStep: 3,
    totalSteps: 4,
    fractionCompleted: 0.75,
    steps: [
      ImportPreparationStep(
        id: "audio", title: EchoCopy("import.presentation.progress.step.audio"),
        state: .completed),
      ImportPreparationStep(
        id: "transcript", title: EchoCopy("import.presentation.progress.step.transcript"),
        state: .completed),
      ImportPreparationStep(
        id: "timing", title: EchoCopy("import.presentation.progress.step.timing"),
        state: .current),
      ImportPreparationStep(
        id: "playback", title: EchoCopy("import.presentation.progress.step.playback"),
        state: .pending),
    ])

  static let ready = ImportReadyPresentation(
    lessonTitle: "Small changes, big difference",
    contentSummary: EchoCopy(
      "import.presentation.ready.content_summary",
      arguments: [
        .raw("42"), .localized("import.presentation.ready.english_captions"),
        .localized("import.presentation.ready.vietnamese_translation"),
      ]),
    practiceSummary: EchoCopy(
      "import.presentation.ready.practice_summary",
      arguments: [
        .localized("import.presentation.ready.uk_reference"), .raw("0.75"), .raw("5"),
      ]))
}
