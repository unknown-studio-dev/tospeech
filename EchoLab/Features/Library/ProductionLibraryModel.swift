import Foundation
import Observation

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
  private var isImportPresentationDismissed = false

  init(service: ProductionImportService) { self.service = service }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      async let loadedLessons = service.librarySummaries()
      async let loadedJobs = service.importJobs()
      lessons = try await loadedLessons
      jobs = try await loadedJobs
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
  func submit(_ request: ProductionImportRequest) async -> ProductionImportJob? {
    do {
      let job = try await service.submit(request)
      jobs.removeAll { $0.id == job.id }
      jobs.insert(job, at: 0)
      error = nil
      showImportStatus(for: job)
      startMonitoring()
      return job
    } catch let failure {
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
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

  func retry(_ job: ProductionImportJob) async {
    do {
      try await service.retry(jobID: job.id)
      await load()
      if let restarted = jobs.first(where: { $0.id == job.id }) {
        showImportStatus(for: restarted)
      }
      startMonitoring()
    } catch let failure {
      self.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
    }
  }

  private func startMonitoring() {
    monitorTask?.cancel()
    guard jobs.contains(where: { !$0.phase.isTerminal }) else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self else { return }
        await self.load()
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
    isImportPresentationDismissed = false
    refreshImportPresentation()
  }

  func dismissImportPresentation(jobID: UUID? = nil) {
    guard jobID == nil || jobID == watchedImportJobID else { return }
    isImportPresentationDismissed = true
    importPresentation = nil
  }

  private func refreshImportPresentation() {
    guard !isImportPresentationDismissed,
      let watchedImportJobID,
      let job = jobs.first(where: { $0.id == watchedImportJobID })
    else {
      importPresentation = nil
      return
    }
    let presentation: ImportPreparationPresentation?
    if let progress = ProductionImportPresentationMapper.progress(for: job) {
      presentation = .progress(progress)
    } else if let lesson = lessons.first(where: { $0.id == job.lessonID }), lesson.isPracticeReady,
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
