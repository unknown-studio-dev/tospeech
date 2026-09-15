import Foundation
import Observation

@MainActor @Observable
final class DictationModel {
  enum Phase { case ready, listening, writing, paused, result }
  let player: any DictationAudioPlaying
  private let storage: any DictationStorage
  private let now: () -> Date
  private var clockTask: Task<Void, Never>?
  private var autosaveTask: Task<Void, Never>?
  private var writeTask: Task<Void, Never>?
  private var playbackID = UUID()
  private var loadID = UUID()
  private var deadline: Date?
  private var pendingWrites: [UUID: DictationProgress] = [:]
  private var writeErrors: [UUID: String] = [:]
  private var queuedWrites = 0
  private(set) var lessonID: UUID?
  private(set) var sentences: [ProductionPreparedSentence] = []
  private(set) var selectedID: UUID?
  private(set) var progress: [UUID: DictationProgress] = [:]
  private(set) var isLoading = false
  private(set) var isPaused = false
  private(set) var isPlaying = false
  private(set) var remainingSeconds: Double?
  var selectedAttemptID: UUID?
  /// The learner's choice for sentences not started yet and for retries. It is
  /// never overwritten by visiting a sentence that was written under another limit.
  var nextTimeLimit: Int? = 25
  /// The last timed value picked, so switching back from "free" restores it.
  private(set) var lastTimedLimit = DictationProgress.defaultTimeLimit
  /// Once the learner touches the limit in this session, Settings stops steering it.
  private var limitChosenInSession = false
  var speed = 0.75
  var error: String?
  private(set) var loadError: String?

  init(storage: any DictationStorage, player: any DictationAudioPlaying = ProductionAudioPlayer(),
    now: @escaping () -> Date = Date.init) {
    self.storage = storage; self.player = player; self.now = now
    player.onFailure = { [weak self] message in
      guard let self else { return }
      self.playbackID = UUID()
      self.isPlaying = false
      self.error = message
    }
  }

  var current: DictationProgress? { selectedID.flatMap { progress[$0] } }
  var sentence: ProductionPreparedSentence? { sentences.first { $0.id == selectedID } }
  var attempt: DictationAttempt? {
    current?.attempts.first { $0.id == selectedAttemptID } ?? current?.latest
  }
  var phase: Phase {
    if current?.draft.submitted == true { return .result }
    if isPaused { return .paused }
    if current?.draft.hasListened == true { return .writing }
    return isPlaying ? .listening : .ready
  }
  var phaseKey: String {
    switch phase {
    case .ready: "dictation.ready"
    case .listening: "dictation.listening"
    case .writing: "dictation.writing"
    case .paused: "dictation.paused"
    case .result: "dictation.result"
    }
  }
  var canEdit: Bool { phase == .writing && !isLoading }
  var completedCount: Int { sentences.filter { progress[$0.id]?.latest != nil }.count }
  var isSaving: Bool { queuedWrites > 0 || autosaveTask != nil }
  var saveError: String? { writeErrors.values.first }
  var canChangeLimit: Bool { current?.draft.hasListened != true && !isPlaying || phase == .result }
  /// What the limit control shows: the locked value while a sentence is being
  /// written, otherwise the choice that applies to the next attempt.
  var displayedTimeLimit: Int? {
    guard let current, current.draft.hasListened, !current.draft.submitted else { return nextTimeLimit }
    return current.draft.timeLimit
  }

  func activate(_ sentences: [ProductionPreparedSentence], preferredID: UUID? = nil) async {
    guard let lessonID = sentences.first?.target.lessonID else { return }
    let token = UUID(); loadID = token
    suspend()
    await writeTask?.value
    guard loadID == token else { return }
    isLoading = true
    self.lessonID = lessonID; self.sentences = sentences
    selectedID = nil; progress = [:]; remainingSeconds = nil; isPaused = false
    loadError = nil
    defer { if loadID == token { isLoading = false } }
    do {
      let saved = try await storage.dictationProgress(lessonID: lessonID)
      guard loadID == token else { return }
      self.lessonID = lessonID; self.sentences = sentences
      progress = Dictionary(uniqueKeysWithValues: saved.map { ($0.revisionID, $0) })
      // Retain any failed save in memory until Retry succeeds; never replace it
      // with an older database snapshot when reopening this lesson.
      for value in pendingWrites.values where value.lessonID == lessonID { progress[value.revisionID] = value }
      selectedID = nil
      select(preferredID.flatMap { id in sentences.first { $0.id == id } }?.id ?? sentences[0].id)
      error = nil
    } catch { self.loadError = error.localizedDescription }
  }

  func reload() async { await activate(sentences) }

  func refreshAnnotations(_ values: [ProductionPreparedSentence]) {
    guard values.map(\.id) == sentences.map(\.id) else { return }
    sentences = values
  }

  func select(_ id: UUID) {
    guard loadError == nil, let sentence = sentences.first(where: { $0.id == id }), selectedID != id else { return }
    suspend()
    selectedID = id; selectedAttemptID = nil
    if progress[id] == nil {
      progress[id] = DictationProgress(lessonID: sentence.target.lessonID, revisionID: id,
        targetText: sentence.target.text, draft: .init(timeLimit: nextTimeLimit))
    } else if var value = progress[id], !value.draft.hasListened, !value.draft.submitted,
      value.draft.timeLimit != nextTimeLimit {
      // A sentence nobody has listened to yet follows the current choice.
      value.draft.timeLimit = nextTimeLimit
      value.draft.remainingSeconds = nextTimeLimit.map(Double.init)
      progress[id] = value
    }
    remainingSeconds = current?.draft.remainingSeconds
    isPaused = current?.draft.hasListened == true && current?.draft.submitted == false
    error = nil
    persistCurrent()
  }

  /// A row click is an explicit listen/resume action. Restoring selection when
  /// loading a lesson still uses `select` and must remain silent.
  func selectAndListen(_ id: UUID) {
    guard !isLoading, loadError == nil, sentences.contains(where: { $0.id == id }) else { return }
    select(id)
    listen()
  }

  /// The transport's play: a paused sentence resumes its clock and replays, the
  /// same as clicking its row, so the learner is never left with a dead button.
  func listen() {
    guard !isLoading, loadError == nil, current != nil else { return }
    if isPaused { resume() }
    play()
  }

  func step(_ delta: Int) {
    guard let index = sentences.firstIndex(where: { $0.id == selectedID }),
      sentences.indices.contains(index + delta) else { return }
    select(sentences[index + delta].id)
  }

  /// Seeds the limit from Settings for sentences not started yet. A choice made
  /// in this session wins over the preference.
  func applyPreferredLimit(_ value: Int?) {
    guard !limitChosenInSession, value.map({ DictationProgress.timeLimits.contains($0) }) ?? true
    else { return }
    nextTimeLimit = value
    if let value { lastTimedLimit = value }
  }

  func setLimit(_ value: Int?) {
    guard value.map({ DictationProgress.timeLimits.contains($0) }) ?? true, canChangeLimit else { return }
    limitChosenInSession = true
    nextTimeLimit = value
    if let value { lastTimedLimit = value }
    if var current, !current.draft.hasListened {
      current.draft.timeLimit = value; current.draft.remainingSeconds = value.map(Double.init)
      progress[current.revisionID] = current; remainingSeconds = current.draft.remainingSeconds
      persistCurrent()
    }
  }

  func edit(_ text: String) {
    tick()
    guard canEdit, var current else { return }
    let bounded = String(text.prefix(6_000))
    guard ContentMatch.tokens(bounded).count <= 512 else { return }
    current.draft.answer = bounded
    current.updatedAt = now()
    progress[current.revisionID] = current
    autosaveTask?.cancel()
    autosaveTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      self?.autosaveTask = nil
      self?.persistCurrent()
    }
  }

  func play() {
    guard !isLoading, !isPaused, let sentence, current != nil else { return }
    tick()
    // Expiry during this action leaves the result visible and source replay is
    // still allowed; it can never unlock or create a second submission.
    playbackID = UUID(); let token = playbackID
    player.stop(); isPlaying = true; error = nil
    do {
      try player.playSentence(sentence.target, speed: speed) { [weak self] in
        guard let self, self.playbackID == token, self.selectedID == sentence.id else { return }
        self.playbackID = UUID()
        self.isPlaying = false
        guard var current = self.current, !current.draft.submitted else { return }
        current.draft.listenCount += 1
        let firstListen = !current.draft.hasListened
        current.draft.hasListened = true
        self.progress[current.revisionID] = current
        if firstListen { self.startClock() }
        self.persistCurrent()
      }
    } catch { isPlaying = false; self.error = error.localizedDescription }
  }

  func stopPlayback() {
    playbackID = UUID(); player.stop(); isPlaying = false
  }

  func suspend() {
    tick()
    stopPlayback(); clockTask?.cancel(); clockTask = nil
    deadline = nil
    if current?.draft.hasListened == true && current?.draft.submitted == false { isPaused = true }
    persistCurrent()
  }

  func resume() {
    guard isPaused else { return }
    isPaused = false
    if current?.draft.hasListened == true { startClock() }
  }

  private func startClock() {
    isPaused = false
    remainingSeconds = remainingSeconds ?? current?.draft.remainingSeconds
    deadline = remainingSeconds.map { now().addingTimeInterval($0) }
    clockTask?.cancel()
    guard deadline != nil else { clockTask = nil; return }
    clockTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        self?.tick()
      }
    }
    tick()
  }

  /// Uses an absolute deadline, not a decrementing timer; delayed UI ticks do
  /// not grant extra time. The test clock drives the same expiry path. Only the
  /// clock value changes here; the draft is written on save and submit, so a
  /// tick never re-renders the editor the learner is typing in.
  func tick() {
    guard !isPaused, let current, current.draft.hasListened, !current.draft.submitted,
      let deadline else { return }
    remainingSeconds = max(0, deadline.timeIntervalSince(now()))
    if remainingSeconds == 0 { submit(timedOut: true) }
  }

  func submit(timedOut: Bool = false) {
    guard var current, current.draft.hasListened, !current.draft.submitted, !isPaused else { return }
    let expired = deadline.map { $0 <= now() } ?? false
    if let deadline {
      remainingSeconds = max(0, deadline.timeIntervalSince(now()))
      current.draft.remainingSeconds = remainingSeconds
    }
    do {
      try current.submit(timedOut: timedOut || expired, now: now())
      progress[current.revisionID] = current
      selectedAttemptID = current.latest?.id
      deadline = nil; clockTask?.cancel(); clockTask = nil; stopPlayback()
      persistCurrent()
    } catch { self.error = error.localizedDescription }
  }

  func retrySentence() {
    guard var current, current.draft.submitted else { return }
    stopPlayback(); deadline = nil; clockTask?.cancel(); clockTask = nil
    current.draft = .init(timeLimit: nextTimeLimit)
    progress[current.revisionID] = current
    remainingSeconds = current.draft.remainingSeconds
    selectedAttemptID = nil; isPaused = false
    persistCurrent()
  }

  func retrySave() {
    for value in Array(pendingWrites.values) { enqueue(value) }
  }

  func flush() async {
    persistCurrent()
    await writeTask?.value
  }

  private func persistCurrent() {
    autosaveTask?.cancel(); autosaveTask = nil
    guard var value = current else { return }
    value.updatedAt = now()
    if let remainingSeconds { value.draft.remainingSeconds = remainingSeconds }
    progress[value.revisionID] = value
    enqueue(value)
  }

  private func enqueue(_ value: DictationProgress) {
    pendingWrites[value.revisionID] = value
    queuedWrites += 1
    let previous = writeTask
    writeTask = Task { [weak self, storage] in
      await previous?.value
      do {
        try await storage.saveDictationProgress(value)
        guard let self else { return }
        if self.pendingWrites[value.revisionID] == value {
          self.pendingWrites[value.revisionID] = nil
          self.writeErrors[value.revisionID] = nil
        }
      } catch { self?.writeErrors[value.revisionID] = error.localizedDescription }
      self?.queuedWrites -= 1
    }
  }
}
