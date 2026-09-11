import Foundation
import Observation
import OSLog

@MainActor @Observable final class ProductionLibraryModel {
  private let service: ProductionImportService
  private(set) var lessons: [LibraryLessonSummary] = []
  private(set) var jobs: [ProductionImportJob] = []
  private var monitorTask: Task<Void, Never>?
  private(set) var isLoading = false
  var error: EchoCopy?
  private(set) var failedDeletionID: UUID?
  var importPresentation: ProductionImportPresentationContext?
  private var watchedImportJobID: UUID?
  private var watchedImportJob: ProductionImportJob?
  private var isImportPresentationDismissed = false
  private var transcriptionSubProgress: Double?

  init(service: ProductionImportService) { self.service = service }

  func load(showLoadingIndicator: Bool = true) async {
    if showLoadingIndicator { isLoading = true }
    defer { if showLoadingIndicator { isLoading = false } }
    do {
      async let loadedLessons = service.librarySummaries()
      async let loadedJobs = service.importJobs()
      lessons = try await loadedLessons
      jobs = try await loadedJobs
      updateTranscriptionSubProgress()
      refreshImportPresentation()
      error = nil
    } catch let failure {
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
    }
  }

  func resumePendingJobs() async {
    do {
      try await service.resumePendingJobs()
      await load()
    } catch let failure {
      await load()
      do { failedDeletionID = try await service.deletingLessonIDs().first } catch {
        failedDeletionID = nil
      }
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
    }
    startMonitoring()
  }

  @discardableResult
  func submit(_ request: ProductionImportRequest, localeIdentifier: String = "en-GB", whisperModel: String? = nil, transcriptionEngine: String = "whisper", transcriptionModelID: String? = nil, compareWithApple: Bool = true) async -> ProductionImportJob? {
    do {
      let job = try await service.submit(request, localeIdentifier: localeIdentifier, whisperModel: whisperModel, transcriptionEngine: transcriptionEngine, transcriptionModelID: transcriptionModelID, compareWithApple: compareWithApple)
      jobs.removeAll { $0.id == job.id }
      jobs.insert(job, at: 0)
      error = nil
      startMonitoring()
      return job
    } catch let failure {
      Logger(subsystem: "com.unknownstudio.EchoLab", category: "ProductionImport")
        .error("Import submission failed: \(failure.localizedDescription)")
      self.error = EchoCopy(
        (failure as? ProductionImportError)?.presentationDescription ?? "import.submit.failed")
      return nil
    }
  }

  func cancel(_ job: ProductionImportJob) async {
    await cancel(jobID: job.id)
  }

  func cancel(jobID: UUID) async {
    dismissImportPresentation(jobID: jobID)
    await service.cancel(jobID: jobID)
    startMonitoring()
  }

  func retry(_ job: ProductionImportJob, selection: TranscriptionSelection? = nil, compareWithApple: Bool? = nil) async {
    do {
      try await service.retry(jobID: job.id, replacementSelection: selection, compareWithApple: compareWithApple)
      await load()
      if let restarted = jobs.first(where: { $0.id == job.id }) {
        showImportStatus(for: restarted)
      }
      startMonitoring()
    } catch let failure {
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
    }
  }

  func retryUsingSettings(_ job: ProductionImportJob, preferences: Preferences) async {
    do {
      try await service.retryUsingSettings(jobID: job.id, engine: preferences.transcriptionEngine,
        whisperModel: preferences.activeTranscriptionModel, compareWithApple: preferences.compareTranscriptWithApple)
      await load()
      if let restarted = jobs.first(where: { $0.id == job.id }) { showImportStatus(for: restarted) }
      startMonitoring()
    } catch {
      self.error = EchoCopy((error as? ProductionImportError)?.presentationDescription ?? "import.submit.failed")
    }
  }

  private func startMonitoring() {
    monitorTask?.cancel()
    guard jobs.contains(where: { !$0.phase.isTerminal }) else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self else { return }
        await self.load(showLoadingIndicator: false)
        if !self.jobs.contains(where: { !$0.phase.isTerminal }) { return }
      }
    }
  }

  @discardableResult
  func delete(_ lesson: LibraryLessonSummary) async -> Bool {
    do {
      try await service.deleteLesson(id: lesson.id, expectedGeneration: lesson.generation)
      failedDeletionID = nil
      await load()
      return true
    } catch let failure {
      do {
        failedDeletionID =
          try await service.deletingLessonIDs().contains(lesson.id)
          ? lesson.id : nil
      } catch { failedDeletionID = nil }
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
      return false
    }
  }

  func retryDeletion() async {
    guard let failedDeletionID else { return }
    do {
      try await service.retryDeletion(id: failedDeletionID)
      self.failedDeletionID = nil
      await load()
    } catch let failure {
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
    }
  }

  func report(_ failure: any Error) {
    error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
  }

  func showImportStatus(for job: ProductionImportJob) {
    watchedImportJobID = job.id
    watchedImportJob = job
    isImportPresentationDismissed = false
    refreshImportPresentation()
  }

  func dismissImportPresentation(jobID: UUID? = nil) {
    guard jobID == nil || jobID == watchedImportJobID else { return }
    isImportPresentationDismissed = true
    importPresentation = nil
    watchedImportJob = nil
  }

  private func updateTranscriptionSubProgress() {
    guard let watchedImportJobID,
      let job = jobs.first(where: { $0.id == watchedImportJobID }),
      job.phase == .preparingTranscript
    else {
      transcriptionSubProgress = nil
      return
    }
    transcriptionSubProgress = service.transcriptionProgress(jobID: watchedImportJobID)
  }

  private func refreshImportPresentation() {
    guard !isImportPresentationDismissed,
      let watchedImportJobID
    else {
      importPresentation = nil
      return
    }
    let currentJob = jobs.first(where: { $0.id == watchedImportJobID })
    if let currentJob { watchedImportJob = currentJob }
    let lesson = lessons.first(where: { $0.id == (currentJob ?? watchedImportJob)?.lessonID })
    let job: ProductionImportJob?
    if let currentJob {
      job = currentJob
    } else if let snapshot = watchedImportJob, lesson?.isPracticeReady == true {
      job = ProductionImportJob(
        id: snapshot.id, lessonID: snapshot.lessonID, title: snapshot.title, phase: .ready,
        runToken: snapshot.runToken, expectedGeneration: snapshot.expectedGeneration,
        error: nil, createdAt: snapshot.createdAt, updatedAt: Date())
    } else {
      job = nil
    }
    guard let job else {
      importPresentation = nil
      return
    }
    let presentation: ImportPreparationPresentation?
    if let progress = ProductionImportPresentationMapper.progress(
      for: job, subProgress: transcriptionSubProgress)
    {
      presentation = .progress(progress)
    } else if let lesson, lesson.isPracticeReady,
      let ready = ProductionImportPresentationMapper.ready(
        for: job, lesson: lesson)
    {
      presentation = .ready(ready)
    } else {
      presentation = nil
    }
    guard let presentation else {
      importPresentation = nil
      return
    }
    importPresentation = ProductionImportPresentationContext(
      jobID: job.id, lessonID: job.lessonID, presentation: presentation)
  }
}
