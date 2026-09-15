import Foundation

/// Maps durable production-import checkpoints into the display-only preparation sheet.
/// It deliberately exposes only checkpoints the current importer persists.
enum ProductionImportPresentationMapper {
  /// `subProgress` (0...1) advances the bar *within* the current step. The
  /// transcription step is minutes long, so without it the bar sits frozen at
  /// one tick; the caller supplies the engine's fraction during that step only.
  static func progress(
    for job: ProductionImportJob, subProgress: Double? = nil
  ) -> ImportProgressPresentation? {
    guard let currentIndex = currentIndex(for: job.phase) else { return nil }
    let steps = stepKeys.enumerated().map { index, key in
      ImportPreparationStep(
        id: key,
        title: EchoCopy(key),
        state: index < currentIndex ? .completed : index == currentIndex ? .current : .pending)
    }

    let fraction: Double
    if let subProgress {
      let clamped = min(1, max(0, subProgress))
      fraction = (Double(currentIndex) + clamped) / Double(stepKeys.count)
    } else {
      fraction = Double(currentIndex + 1) / Double(stepKeys.count)
    }

    return ImportProgressPresentation(
      currentTask: EchoCopy(stepKeys[currentIndex]),
      currentStep: currentIndex + 1,
      totalSteps: stepKeys.count,
      fractionCompleted: fraction,
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
      practiceSummary: lesson.wordTimingReviewCount > 0
        ? EchoCopy("speech.import.timing_review", arguments: [.raw(String(lesson.wordTimingReviewCount))])
        : EchoCopy("import.presentation.ready.practice_available"))
  }

  private static let stepKeys = [
    "import.presentation.preparation.step.audio",
    "import.combined.sources",
    "import.presentation.preparation.step.timing",
    "import.presentation.preparation.step.publishing",
  ]

  private static func currentIndex(for phase: ProductionImportPhase) -> Int? {
    switch phase {
    case .resolving, .downloadingAudio, .probing: 0
    case .fetchingCaptions, .preparingSpeechModel: 1
    case .preparingTranscript, .checkingTiming: 2
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
