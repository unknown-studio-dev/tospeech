import Foundation

/// Maps durable production-import checkpoints into the display-only preparation sheet.
/// It deliberately exposes only checkpoints the current importer persists.
enum ProductionImportPresentationMapper {
  static func progress(for job: ProductionImportJob) -> ImportProgressPresentation? {
    guard let currentIndex = currentIndex(for: job.phase) else { return nil }
    let steps = stepKeys.enumerated().map { index, key in
      ImportPreparationStep(
        id: key,
        title: EchoCopy(key),
        state: index < currentIndex ? .completed : index == currentIndex ? .current : .pending)
    }

    return ImportProgressPresentation(
      currentTask: EchoCopy(stepKeys[currentIndex]),
      currentStep: currentIndex + 1,
      totalSteps: stepKeys.count,
      fractionCompleted: Double(currentIndex + 1) / Double(stepKeys.count),
      steps: steps)
  }

  static func ready(
    for job: ProductionImportJob, lesson: LibraryLessonSummary
  ) -> ImportReadyPresentation? {
    guard job.phase == .ready, lesson.preparedSentenceCount > 0 else { return nil }
    return ImportReadyPresentation(
      lessonTitle: lesson.title,
      contentSummary: EchoCopy(
        "import.presentation.ready.prepared_summary",
        arguments: [.raw(String(lesson.preparedSentenceCount))]),
      practiceSummary: EchoCopy("import.presentation.ready.practice_available"))
  }

  private static let stepKeys = [
    "import.presentation.preparation.step.audio",
    "import.presentation.preparation.step.captions",
    "import.presentation.preparation.step.timing",
    "import.presentation.preparation.step.publishing",
  ]

  private static func currentIndex(for phase: ProductionImportPhase) -> Int? {
    switch phase {
    case .resolving, .downloadingAudio, .probing: 0
    case .fetchingCaptions: 1
    case .preparingTranscript: 2
    case .publishing: 3
    case .ready, .failed, .cancelled: nil
    }
  }
}

struct ProductionImportPresentationContext: Identifiable, Equatable {
  let jobID: UUID
  let lessonID: UUID
  let presentation: ImportPreparationPresentation

  var id: UUID { jobID }
}
