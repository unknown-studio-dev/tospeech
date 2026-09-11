import Foundation
import Observation

@MainActor @Observable
final class EchoStore {
  var lessons: [Lesson] { didSet { persist() } }
  var takes: [PracticeTake] { didSet { persist() } }
  var preferences: Preferences { didSet { persist() } }
  var packages: [ModelPackage] { didSet { persist() } }
  var selectedLessonID: String? { didSet { persist() } }
  var selectedSentenceID: String? { didSet { persist() } }
  var route: AppRoute = .library
  var reviewTakeID: String?
  var message: EchoCopy?
  var storageError: EchoCopy?
  var importJob: PreviewImportJob?
  var switchingEngine = false
  var failNextAssessment = false
  @ObservationIgnored private let repository: PreviewRepository
  @ObservationIgnored private var ready = false
  @ObservationIgnored var importTask: Task<Void, Never>?
  @ObservationIgnored var assessmentTask: Task<Void, Never>?
  @ObservationIgnored var packageTasks: [EngineID: Task<Void, Never>] = [:]
  @ObservationIgnored var productionNavigationGuard: ((AppRoute) -> Bool)?
  @ObservationIgnored lazy var practice = PracticeController(store: self)

  init(snapshot: PreviewSnapshot? = nil, repository: PreviewRepository = .local) {
    self.repository = repository
    var recoveryError: EchoCopy?
    let initial: PreviewSnapshot
    if let snapshot {
      initial = snapshot
    } else {
      do { initial = try repository.load() ?? PreviewFixtures.snapshot() } catch {
        initial = PreviewFixtures.snapshot()
        recoveryError = EchoCopy(
          "storage.restore_failed", arguments: [.raw(error.localizedDescription)])
      }
    }
    lessons = initial.lessons
    takes = initial.takes
    preferences = initial.preferences
    packages = initial.packages
    selectedLessonID = initial.selectedLessonID
    selectedSentenceID = initial.selectedSentenceID
    storageError = recoveryError
    for i in takes.indices {
      for j in takes[i].assessments.indices
      where [.queued, .running].contains(takes[i].assessments[j].status) {
        takes[i].assessments[j].status = .failed
        takes[i].assessments[j].error = "Preview interrupted. Retry assessment."
      }
    }
    for i in packages.indices where [.downloading, .verifying].contains(packages[i].status) {
      packages[i].status = .failed
      packages[i].error = "Preview installation interrupted. Retry."
    }
    ready = recoveryError == nil
  }
  var selectedLesson: Lesson? { lessons.first { $0.id == selectedLessonID } }
  var selectedSentence: LessonSentence? {
    selectedLesson?.sentences.first { $0.id == selectedSentenceID }
      ?? selectedLesson?.sentences.first
  }
  var pendingAssessmentCount: Int {
    takes.flatMap(\.assessments).filter { [.queued, .running].contains($0.status) }.count
  }
  var snapshot: PreviewSnapshot {
    PreviewSnapshot(
      lessons: lessons, takes: takes, preferences: preferences, packages: packages,
      selectedLessonID: selectedLessonID, selectedSentenceID: selectedSentenceID)
  }

  func persist() {
    guard ready else { return }
    do {
      try repository.save(snapshot)
      storageError = nil
    } catch {
      storageError = EchoCopy(
        "storage.save_failed", arguments: [.raw(error.localizedDescription)])
    }
  }
  func navigate(_ destination: AppRoute) {
    guard productionNavigationGuard?(destination) ?? true else { return }
    guard practice.interrupt() else { return }
    route = destination
  }
  func openLesson(_ id: String, sentenceID: String? = nil, takeID: String? = nil) {
    guard lessons.contains(where: { $0.id == id }), practice.interrupt() else { return }
    if selectedLessonID != id || (sentenceID != nil && sentenceID != selectedSentenceID) {
      selectedSentenceID = nil
      practice.resetTarget()
    }
    selectedLessonID = id
    selectedSentenceID = sentenceID ?? selectedSentenceID ?? selectedLesson?.sentences.first?.id
    reviewTakeID = takeID
    route = .shadowing
  }
  func selectSentence(_ id: String) {
    guard practice.interrupt() else { return }
    selectedSentenceID = id
    reviewTakeID = nil
    practice.clearScope()
    practice.playSentence()
  }
  func commitPreviewTake(_ take: PracticeTake) -> Bool {
    guard ready else {
      storageError = EchoCopy("Resolve the preview storage recovery before saving.")
      return false
    }
    var next = snapshot
    if !next.takes.contains(where: { $0.id == take.id }) { next.takes.append(take) }
    do {
      try repository.save(next)
      takes = next.takes
      storageError = nil
      return true
    } catch {
      storageError = EchoCopy(
        "storage.take_save_failed", arguments: [.raw(error.localizedDescription)])
      return false
    }
  }
  func saveSentence(_ sentence: LessonSentence, lessonID: String, expectedRevision: Int) -> String?
  {
    guard let l = lessons.firstIndex(where: { $0.id == lessonID }),
      let s = lessons[l].sentences.firstIndex(where: { $0.id == sentence.id })
    else { return "The lesson is no longer available." }
    guard lessons[l].sentences[s].revision == expectedRevision else {
      return "This sentence changed. Reopen the editor before saving."
    }
    if let error = TimingRules.validate(sentence, duration: lessons[l].duration) { return error }
    var updated = sentence
    let current = lessons[l].sentences[s]
    updated.baseline =
      current.baseline
      ?? SentenceBaseline(
        text: current.text, translation: current.translation, span: current.span,
        words: current.words)
    updated.revision = current.revision + 1
    guard ready else { return "Resolve the preview storage recovery before saving." }
    var next = snapshot
    next.lessons[l].sentences[s] = updated
    do { try repository.save(next) } catch {
      storageError = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
      return "Could not save sentence changes. Your draft is retained."
    }
    lessons = next.lessons
    practice.resetTarget()
    message = EchoCopy("Sentence changes saved · old takes keep their original context.")
    return nil
  }
  func deleteLesson(_ id: String) -> Bool {
    if selectedLessonID == id && !practice.interrupt() { return false }
    lessons.removeAll { $0.id == id }
    takes.removeAll { $0.lessonID == id }
    if selectedLessonID == id {
      selectedLessonID = lessons.first?.id
      selectedSentenceID = lessons.first?.sentences.first?.id
      reviewTakeID = nil
      route = .library
    }
    message = EchoCopy("Lesson and its preview history deleted.")
    return true
  }
  func restoreDemo() {
    guard practice.interrupt() else { return }
    let language = preferences.language
    importTask?.cancel()
    assessmentTask?.cancel()
    assessmentTask = nil
    for task in packageTasks.values { task.cancel() }
    packageTasks = [:]
    importJob = nil
    let value = PreviewFixtures.snapshot()
    ready = true
    lessons = value.lessons
    takes = value.takes
    preferences = value.preferences
    preferences.language = language
    packages = value.packages
    selectedLessonID = value.selectedLessonID
    selectedSentenceID = value.selectedSentenceID
    practice.resetTarget()
    reviewTakeID = nil
    route = .library
    persist()
    message = EchoCopy("Demo data restored.")
  }
}
