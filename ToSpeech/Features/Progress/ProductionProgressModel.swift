import Foundation
import Observation

/// Feeds the Progress screen from the production database. UI-only: it maps stored
/// takes and prepared sentences into the domain `PracticeTake`/`Lesson` shapes the
/// approved D03 layout already consumes, following the same
/// `ProductionLibraryModel`/`ProductionShadowingModel` pattern.
///
/// The take-level overall score is aggregated from the real per-phone scores the active
/// engine (Phone Accentedness Scorer) already stores in `pronunciation_jobs`; it is
/// never fabricated. Takes an engine cannot score (or no-speech takes) carry no numeric
/// score, so the trend and first→latest comparison fall back to their existing empty
/// states rather than showing a made-up number. Stats, history and the header use real
/// data throughout.
@MainActor @Observable final class ProductionProgressModel {
  private let importService: ProductionImportService
  private let practiceService: ProductionPracticeService

  private(set) var summaries: [LibraryLessonSummary] = []
  private(set) var lessons: [Lesson] = []
  private(set) var takes: [PracticeTake] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var loadedLessonID: String?
  var error: EchoCopy?

  init(importService: ProductionImportService, practiceService: ProductionPracticeService) {
    self.importService = importService
    self.practiceService = practiceService
  }

  /// Loads the lesson list and the detail (prepared sentences + takes) for one lesson.
  /// Only the loaded lesson carries `sentences`; the others are shells with id/title so
  /// the "change video" control and the empty check work without loading every lesson.
  func load(
    lessonID requested: String? = nil, accent: ReferenceAccent = .uk,
    showLoadingIndicator: Bool = true
  ) async {
    if showLoadingIndicator { isLoading = true }
    defer {
      hasLoaded = true
      if showLoadingIndicator { isLoading = false }
    }
    do {
      let summaries = try await importService.librarySummaries()
      var lessons = summaries.map { Self.lessonShell(from: $0, accent: accent) }
      let targetID =
        requested.flatMap(UUID.init(uuidString:)).flatMap { id in
          summaries.contains { $0.id == id } ? id : nil
        } ?? summaries.first?.id
      guard let targetID else {
        self.summaries = summaries
        self.lessons = lessons
        self.takes = []
        self.loadedLessonID = nil
        error = nil
        return
      }
      async let preparedLoad = practiceService.preparedSentences(lessonID: targetID)
      async let storedLoad = practiceService.takes(lessonID: targetID)
      async let savedLoad = practiceService.savedTakeSentences(lessonID: targetID)
      async let jobsLoad = practiceService.pronunciationJobs(lessonID: targetID)
      let prepared = try await preparedLoad
      let stored = try await storedLoad
      let saved = try await savedLoad
      let jobs = try await jobsLoad
      if let index = lessons.firstIndex(where: { $0.id == targetID.uuidString }) {
        lessons[index].sentences = prepared.enumerated().map {
          $0.element.lessonSentence(number: $0.offset + 1)
        }
      }
      self.summaries = summaries
      self.lessons = lessons
      self.takes = Self.practiceTakes(stored: stored, saved: saved, prepared: prepared, jobs: jobs)
      self.loadedLessonID = targetID.uuidString
      error = nil
    } catch is CancellationError {
      return
    } catch let failure {
      error = EchoCopy.describing(failure)
    }
  }

  /// Maps stored takes to domain takes, numbering them 1…n within each sentence by
  /// capture time, preserving the *recorded* sentence revision (via the saved snapshot)
  /// so takes from different revisions are never treated as comparable, and attaching the
  /// real stored assessments for each take.
  static func practiceTakes(
    stored: [ProductionStoredTake],
    saved: [UUID: ProductionPreparedSentence],
    prepared: [ProductionPreparedSentence],
    jobs: [PronunciationJob]
  ) -> [PracticeTake] {
    let preparedByRevision = Dictionary(
      prepared.map { ($0.target.segmentRevisionID, $0) }, uniquingKeysWith: { first, _ in first })
    let sentenceNumberBySegment = Dictionary(
      prepared.enumerated().map { ($0.element.target.segmentID, $0.offset + 1) },
      uniquingKeysWith: { first, _ in first })
    let jobsByTake = Dictionary(grouping: jobs, by: \.takeID)

    func sentence(for take: ProductionStoredTake) -> ProductionPreparedSentence? {
      saved[take.id] ?? preparedByRevision[take.segmentRevisionID]
    }
    func sentenceKey(_ take: ProductionStoredTake) -> UUID {
      sentence(for: take)?.target.segmentID ?? take.segmentRevisionID
    }

    var numberByTake: [UUID: Int] = [:]
    for (_, group) in Dictionary(grouping: stored, by: sentenceKey) {
      for (index, take) in group.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
        numberByTake[take.id] = index + 1
      }
    }
    return
      stored
      .compactMap { take -> PracticeTake? in
        guard let sentence = sentence(for: take) else { return nil }
        let sentenceNumber = sentenceNumberBySegment[sentence.target.segmentID] ?? 1
        var mapped = sentence.practiceTake(
          take, number: numberByTake[take.id] ?? 1, sentenceNumber: sentenceNumber)
        mapped.assessments = assessmentResults(jobs: jobsByTake[take.id] ?? [])
        return mapped
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /// Maps a take's stored pronunciation jobs into domain `AssessmentResult`s, oldest
  /// first (so `latestAssessment` is the newest). Provenance — engine, accent, version
  /// and configuration — all come from the real job; the overall score is aggregated
  /// from real per-phone scores and is `nil` for engines/takes that produce none.
  static func assessmentResults(jobs: [PronunciationJob]) -> [AssessmentResult] {
    jobs.sorted { $0.createdAt < $1.createdAt }.map { job in
      AssessmentResult(
        id: job.id.uuidString,
        engine: engine(forProvenance: job.provenance),
        version: job.result?.qualityPolicy ?? job.provenance,
        accent: job.accent,
        configuration: job.provenance,
        status: assessmentStatus(job.status),
        score: job.status == .complete ? job.result.flatMap(overallScore) : nil,
        error: job.error,
        createdAt: job.createdAt)
    }
  }

  /// The take's overall pronunciation score (0–100): the mean of the real per-phone
  /// scores the active engine (Phone Accentedness Scorer) emits for scored phones.
  /// Returns `nil` when no phone carries a numeric score (other engines, or no speech),
  /// so unscored takes are never turned into a fabricated number or a zero.
  static func overallScore(_ evidence: PronunciationEvidence) -> Double? {
    let scores =
      evidence.words
      .filter(\.supported)
      .flatMap(\.phones)
      .filter { $0.kind == .scored }
      .compactMap(\.score)
    guard !scores.isEmpty else { return nil }
    return scores.reduce(0, +) / Double(scores.count)
  }

  static func engine(forProvenance provenance: String) -> EngineID {
    if provenance.hasPrefix("Phone Scorer") { return .phone }
    if provenance.hasPrefix("UK Reference") { return .ukReference }
    if provenance.hasPrefix("PhoneticXeus") { return .phoneticXeus }
    return .buddy
  }

  static func assessmentStatus(_ status: PronunciationJob.Status) -> AssessmentStatus {
    switch status {
    case .queued: .queued
    case .running: .running
    case .complete: .complete
    case .failed, .unrecognized: .failed
    }
  }

  /// A lesson list entry without sentences. Accent is not stored per lesson in
  /// production (it lives per assessment), so the header uses the learner's chosen
  /// reference accent (`Preferences.accent`); deliberately switching accents may make
  /// the label lag, which is acceptable. Duration/title/thumbnail come from the summary.
  static func lessonShell(from summary: LibraryLessonSummary, accent: ReferenceAccent) -> Lesson {
    Lesson(
      id: summary.id.uuidString, title: summary.title, author: summary.author ?? "",
      thumbnail: "", duration: summary.duration ?? 0, accent: accent,
      sourceURL: nil, createdAt: summary.createdAt, sentences: [],
      thumbnailURL: summary.thumbnailURL)
  }
}
