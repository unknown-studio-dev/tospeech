import Foundation
import Testing
@preconcurrency import Speech

@testable import ToSpeech

@MainActor @Suite(.serialized)
struct PracticeLifecycleTests {
  private func store() -> EchoStore {
    EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
  }

  @Test func lateMicrophonePermissionCannotStartCaptureOnAnotherSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MicPermission-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    var permissionCompletion: CheckedContinuation<MicrophoneAuthorization, Never>?
    let model = try await sequenceModel(root: root, playback: playback,
      currentAuthorization: { .notDetermined }, requestPermission: {
        await withCheckedContinuation { permissionCompletion = $0 }
      })
    model.listenThenRecord()
    playback.completions[0]()
    for _ in 0..<50 {
      if permissionCompletion != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let completion = try #require(permissionCompletion)
    let next = try #require(model.targets.last)
    model.select(next)
    completion.resume(returning: .granted)
    await Task.yield()
    #expect(model.selectedTarget == next)
    #expect(model.controller.phase == .idle)
    #expect(!model.controller.hasListened)
  }

  @Test func duplicateRecordAndPlayCannotReplaceAnActiveCountdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MicCountdown-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback, currentAuthorization: { .granted })
    var preferences = Preferences()
    preferences.countdown = 10
    model.applyPreferences(preferences)
    model.listenThenRecord()
    playback.completions[0]()
    for _ in 0..<50 {
      if model.controller.phase == .countdown { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.controller.phase == .countdown)
    model.record()
    model.listen()
    #expect(model.controller.phase == .countdown)
    #expect(playback.targets.count == 1)
    model.cancelCountdown()
    #expect(model.controller.phase == .paused)
  }

  @Test func directRecordingStartsCountdownWithoutPlayingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectCapture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(
      root: root, playback: playback, currentAuthorization: { .granted })
    var preferences = Preferences()
    preferences.countdown = 10
    model.applyPreferences(preferences)

    model.record()
    for _ in 0..<50 {
      if model.controller.phase == .countdown { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.controller.phase == .countdown)
    #expect(playback.targets.isEmpty)
    #expect(!model.controller.hasListened)
  }

  @Test func microphoneCheckNeverStartsPlaybackOrRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MicCheck-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(
      root: root, playback: playback, currentAuthorization: { .notDetermined },
      requestPermission: { .denied })

    model.checkMicrophonePermission()
    for _ in 0..<50 {
      if model.controller.permission == .denied { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.controller.permission == .denied)
    #expect(model.controller.phase == .idle)
    #expect(model.controller.error == nil)
    #expect(playback.targets.isEmpty)
  }

  @Test func phrasePreviewPreparationStopsRepeatAndIgnoresLateSentenceCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkPreview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback)
    let first = try #require(model.selectedTarget)
    model.listenLoop()
    let completion = try #require(playback.completions.first)
    model.controller.prepareForAuxiliaryPlayback()
    completion()
    #expect(model.controller.phase == .paused)
    #expect(!model.controller.isRepeating)
    #expect(!model.controller.canResumeSource)
    #expect(model.selectedTarget == first)
    #expect(playback.targets.count == 1)
  }

  @Test(arguments: [false, true])
  func productionRepeatOnePlaysNextSentenceAndStopsAtTheEnd(repeating: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sequence-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback)
    let first = try #require(model.targets.first)
    let last = try #require(model.targets.last)
    if repeating { model.listenLoop() } else { model.listen() }
    #expect(playback.targets.map(\.segmentRevisionID) == [first.segmentRevisionID])
    let staleCompletion = try #require(playback.completions.first)
    staleCompletion()
    #expect(model.selectedTarget?.segmentRevisionID == last.segmentRevisionID)
    #expect(model.controller.phase == .listening)
    #expect(model.controller.round == 1)
    #expect(model.controller.isRepeating == repeating)
    #expect(playback.targets.map(\.segmentRevisionID) == [first.segmentRevisionID, last.segmentRevisionID])
    #expect(playback.speeds == [0.75, 0.75])
    staleCompletion() // A late completion from the previous sentence must be ignored.
    #expect(playback.targets.count == 2)
    #expect(model.controller.phase == .listening)
    playback.completions[1]()
    #expect(model.selectedTarget?.segmentRevisionID == last.segmentRevisionID)
    #expect(model.controller.phase == .paused)
    #expect(model.controller.hasListened)
    #expect(playback.targets.count == 2)
  }

  @Test func productionPauseFailureAndMultipleRepeatsDoNotAutoAdvance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sequence-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback)
    let first = try #require(model.selectedTarget)
    model.listen()
    model.pause()
    playback.completions[0]()
    #expect(model.controller.phase == .paused)
    #expect(model.selectedTarget == first)
    #expect(playback.targets.count == 1)

    model.select(first)
    playback.failure = .sourceUnavailable
    model.listen()
    #expect(model.controller.error == .sourceUnavailable)
    #expect(model.selectedTarget == first)
    #expect(playback.targets.count == 1)
    playback.failure = nil

    var preferences = Preferences()
    preferences.repeats = 2
    preferences.autoRecord = false
    model.applyPreferences(preferences)
    model.select(first)
    model.listenLoop()
    playback.completions[1]()
    #expect(model.controller.round == 2)
    #expect(model.selectedTarget == first)
    playback.completions[2]()
    #expect(model.controller.phase == .paused)
    #expect(model.selectedTarget == first)
    #expect(playback.targets.allSatisfy { $0.segmentRevisionID == first.segmentRevisionID })
  }

  @Test func changingSpeedUpdatesTheCurrentSourceWithoutRestartingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSpeed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback)
    model.listen()
    var preferences = Preferences()
    preferences.speed = 1.25
    model.applyPreferences(preferences)
    #expect(playback.speedUpdates == [1.25])
    #expect(playback.targets.count == 1)
    #expect(model.controller.phase == .listening)
  }

  @Test(arguments: [false, true])
  func ordinaryPlayAndLoopHonorAutomaticRecording(repeating: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRecord-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = SequencePlaybackSpy()
    let model = try await sequenceModel(root: root, playback: playback, currentAuthorization: { .granted })
    let sentence = try #require(model.selectedTarget)
    var preferences = Preferences()
    preferences.repeats = 1
    preferences.autoRecord = true
    preferences.countdown = 10
    model.applyPreferences(preferences)
    #expect(model.controller.phase == .idle) // Arming alone never opens the mic.
    if repeating { model.listenLoop() } else { model.listen() }
    #expect(model.controller.phase == .listening)
    playback.completions[0]()
    for _ in 0..<50 {
      if model.controller.phase == .countdown { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.controller.phase == .countdown)
    #expect(model.selectedTarget == sentence)
    #expect(playback.targets.count == 1)
    model.cancelCountdown()
    model.pause()
  }

  @Test(arguments: [false, true])
  func repeatOneKeepsAutomaticRecordingOnTheCurrentSentence(repeating: Bool) {
    let store = store()
    store.preferences.repeats = 1
    store.preferences.autoRecord = true
    store.practice.permission = "granted"
    let selected = store.selectedSentenceID
    store.practice.playSentence(repeating: repeating)
    store.practice.sourceFinished()
    #expect(store.selectedSentenceID == selected)
    #expect(store.practice.phase == .countdown)
    _ = store.practice.interrupt()
  }

  @Test func previewRepeatOneFollowsTheSameSentenceSequence() throws {
    let store = store()
    store.preferences.repeats = 1
    store.preferences.autoRecord = false
    let sentences = try #require(store.selectedLesson?.sentences)
    store.selectSentence(sentences[0].id)
    store.practice.playSentence()
    store.practice.sourceFinished()
    #expect(store.selectedSentenceID == sentences[1].id)
    #expect(store.practice.phase == .listening)
    _ = store.practice.interrupt()
  }

  @Test(arguments: [SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted])
  func speechPermissionCallbackCanArriveOffMainActor(status: SFSpeechRecognizerAuthorizationStatus) async throws {
    let result = try await AppleSpeechCaptionTranscriber.authorizationStatus(current: .notDetermined) { callback in
      DispatchQueue.global().async {
        #expect(!Thread.isMainThread)
        callback(status)
      }
    }
    #expect(result == status)
    let existing = try await AppleSpeechCaptionTranscriber.authorizationStatus(current: status) { _ in
      Issue.record("Known permission must not request consent again")
    }
    #expect(existing == status)
  }

  @Test func speechCallbackCompletesOnceWhenFrameworkReportsLateErrors() async throws {
    var cleanupCount = 0
    let result = try await SpeechCallbackOperation<Int>().value { completion in
      DispatchQueue.global().async {
        completion(.success(42))
        completion(.failure(AppleSpeechCaptionError.noTranscription))
        completion(.success(99))
      }
      return { cleanupCount += 1 }
    }
    #expect(result == 42)
    await Task.yield()
    #expect(cleanupCount == 1)
  }

  @Test func speechRecognitionTimeoutAndCancellationReleaseTask() async throws {
    var cleanupCount = 0
    await #expect(throws: AppleSpeechCaptionError.timedOut) {
      try await SpeechCallbackOperation<Int>().value(timeout: .milliseconds(10)) { _ in
        return { cleanupCount += 1 }
      }
    }
    #expect(cleanupCount == 1)
    var callback: (@Sendable (Result<Int, any Error>) -> Void)?
    let task = Task { @MainActor in
      try await SpeechCallbackOperation<Int>().value { completion in
        callback = completion
        return { cleanupCount += 1 }
      }
    }
    while callback == nil { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    callback?(.success(42))
    await Task.yield()
    #expect(cleanupCount == 2)
  }

  @Test func openingLessonAndDismissingPreflightDoNotInvokeSpeech() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechConsent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var calls = 0
    let model = try await sequenceModel(root: root, playback: SequencePlaybackSpy()) { _ in
      calls += 1
      throw AppleSpeechCaptionError.permissionDenied
    }
    let targets = model.targets
    #expect(calls == 0)
    #expect(model.canPrepareWordTiming)
    #expect(!model.showingSpeechPreparation)
    model.presentSpeechPreparation()
    #expect(model.showingSpeechPreparation)
    #expect(calls == 0)
    model.dismissSpeechPreparation()
    #expect(calls == 0)
    model.startWordTimingPreparation() // Cannot bypass a dismissed preflight.
    #expect(calls == 0)
    model.presentSpeechPreparation()
    model.startWordTimingPreparation()
    while model.isPreparingWordTiming { await Task.yield() }
    #expect(calls == 1)
    #expect(model.speechPreparationError != nil)
    #expect(model.showingSpeechPreparation)
    #expect(model.targets == targets)
    #expect(model.selectedTarget != nil)
    model.dismissSpeechPreparation()
    #expect(!model.showingSpeechPreparation)
    #expect(model.speechPreparationError == nil)
  }

  @Test func explicitSpeechPreparationPublishesTimingAndRefreshesLesson() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechTiming-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await sequenceModel(root: root, playback: SequencePlaybackSpy()) { _ in
      [CaptionCue(start: 0, end: 1, text: "First.", words: [CaptionWord(text: "First", start: 0, end: 1)]),
       CaptionCue(start: 2, end: 3, text: "Last.", words: [CaptionWord(text: "Last", start: 2, end: 3)])]
    }
    let oldRevisions = model.targets.map(\.segmentRevisionID)
    model.presentSpeechPreparation()
    model.startWordTimingPreparation()
    while model.isPreparingWordTiming { await Task.yield() }
    #expect(model.speechPreparationError == nil)
    #expect(!model.showingSpeechPreparation)
    #expect(model.targets.map(\.segmentRevisionID) != oldRevisions)
    #expect(!model.canPrepareWordTiming)
  }

  private func sequenceModel(
    root: URL, playback: SequencePlaybackSpy,
    transcribe: (@MainActor (URL) async throws -> [CaptionCue])? = nil,
    currentAuthorization: (@MainActor () -> MicrophoneAuthorization)? = nil,
    requestPermission: (@MainActor () async -> MicrophoneAuthorization)? = nil
  ) async throws -> ProductionShadowingModel {
    let paths = BackendPaths(root: root)
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "local", externalID: UUID().uuidString, title: "Sequence"))
    let jobID = UUID(), runToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "First."), CaptionCue(start: 2, end: 3, text: "Last.")],
      source: .parakeet, sampleRate: 16_000, frameCount: 64_000)
    let asset = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/sequence.caf", checksum: "fixture", format: "caf",
      sampleRate: 16_000, frameCount: 64_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: runToken,
      title: lesson.title, author: nil, assets: [asset], segments: segments, checkpointJSON: "{}")
    let service = ProductionPracticeService(database: database, paths: paths)
    let controller = ProductionPracticeController(
      service: service, playSource: playback.play, updateSourceSpeed: playback.updateSpeed,
      currentAuthorization: currentAuthorization, requestPermission: requestPermission)
    let model = ProductionShadowingModel(
      service: service, controller: controller, dictation: DictationModel(storage: database),
      wordTimingPreparer: transcribe.map { AppleSpeechWordTimingPreparer(service: service, transcribe: $0) })
    var preferences = Preferences()
    preferences.repeats = 1
    preferences.autoRecord = false
    preferences.speed = 0.75
    let summary = try #require(try await database.librarySummaries(paths: paths).first)
    model.open(summary, preferences: preferences)
    for _ in 0..<100 {
      if model.selectedTarget != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.targets.count == 2)
    _ = try #require(model.selectedTarget)
    return model
  }

  @Test func manualRecordingCanStartImmediately() {
    let store = store()
    store.practice.permission = "granted"
    store.practice.requestRecord()
    #expect(store.practice.phase == .countdown)
    #expect(!store.practice.phase.isCapture)
    store.practice.advance(by: 2)
    #expect(store.practice.phase == .awaitingSpeech)
    store.practice.discardPending()
  }

  @Test func openingAnotherLessonInvalidatesPreviouslyHeardSource() {
    let store = store()
    store.practice.permission = "granted"
    store.practice.playSentence()
    store.practice.sourceFinished()
    #expect(store.practice.hasListened)
    store.openLesson(store.lessons[1].id)
    #expect(!store.practice.hasListened)
    store.practice.requestRecord()
    #expect(store.practice.phase == .countdown)
    store.practice.advance(by: 2)
    store.practice.speechDetected()
    store.practice.finishRecording()
    store.practice.commitPending()
    #expect(store.takes.last?.lessonID == store.lessons[1].id)
    store.cancelAssessments()
  }

  @Test func noSpeechIsSavedWithoutAssessment() {
    let store = store()
    store.practice.permission = "granted"
    store.practice.simulatedOutcome = .noSpeech
    store.practice.requestRecord()
    store.practice.advance(by: 2)
    store.practice.advance(by: 1)
    store.practice.finishRecording()
    store.practice.commitPending()
    let take = store.takes.last!
    #expect(take.outcome == .noSpeech)
    #expect(take.assessments.isEmpty)
  }

  @Test func failedSaveBlocksNavigationAndRetryDoesNotDuplicate() {
    let store = store()
    let before = store.takes.count
    store.practice.permission = "granted"
    store.practice.requestRecord()
    store.practice.advance(by: 2)
    store.practice.speechDetected()
    store.practice.advance(by: 1)
    store.practice.simulateSaveFailure = true
    store.practice.finishRecording()
    store.practice.commitPending()
    #expect(store.practice.phase == .saveFailed)
    #expect(store.takes.count == before)
    store.route = .shadowing
    store.navigate(.library)
    #expect(store.route == .shadowing)
    store.navigate(.settings)
    #expect(store.route == .shadowing)
    store.practice.simulateSaveFailure = false
    store.practice.commitPending()
    store.practice.commitPending()
    #expect(store.takes.count == before + 1)
    #expect(store.practice.pendingTake == nil)
    store.cancelAssessments()
  }

  @Test(arguments: [AppRoute.library, .settings])
  func navigationKeepsInterruptedTakeWithoutScore(destination: AppRoute) {
    let store = store()
    store.practice.permission = "granted"
    store.practice.requestRecord()
    store.practice.advance(by: 2)
    store.practice.speechDetected()
    store.practice.advance(by: 0.5)
    store.navigate(destination)
    #expect(store.route == destination)
    #expect(store.takes.last?.outcome == .interrupted)
    #expect(store.takes.last?.assessments.isEmpty == true)
  }

  @Test func settingsNavigationPausesListeningAndPreservesLessonSelection() {
    let store = store()
    store.route = .shadowing
    let lesson = store.selectedLesson?.id
    let sentence = store.selectedSentence?.id
    store.practice.playSentence(repeating: true)
    store.navigate(.settings)
    #expect(store.route == .settings)
    #expect(store.practice.phase == .paused)
    store.navigate(.shadowing)
    #expect(store.selectedLesson?.id == lesson)
    #expect(store.selectedSentence?.id == sentence)
    #expect(store.practice.phase == .paused)
  }

  @Test func wordPreviewPausesRepeatWithoutChangingReferenceRange() throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    let word = try #require(sentence.words.first)
    store.practice.playSentence(repeating: true)
    store.practice.previewWord(sentence: sentence, wordID: word.id)
    #expect(store.practice.phase == .paused)
    #expect(store.practice.sourcePosition == word.span?.start)
    store.practice.previewReference(word: word, accent: .us)
    #expect(store.selectedSentence?.span == sentence.span)
    #expect(store.selectedSentence?.words == sentence.words)
  }

  @Test func takeSnapshotDoesNotFollowLaterEdits() throws {
    let store = store()
    let original = try #require(store.takes.first)
    var sentence = original.sourceSnapshot
    sentence.translation = "Bản dịch mới"
    #expect(
      store.saveSentence(sentence, lessonID: original.lessonID, expectedRevision: sentence.revision)
        == nil)
    #expect(store.takes.first?.sourceSnapshot == original.sourceSnapshot)
    #expect(store.selectedSentence?.translation == "Bản dịch mới")
    #expect(
      store.saveSentence(sentence, lessonID: original.lessonID, expectedRevision: sentence.revision)
        != nil)
  }

  @Test func queuedAssessmentLocksEngineIdentity() throws {
    let store = store()
    let id = try #require(store.takes.first?.id)
    store.requestAssessment(takeID: id)
    let requested = try #require(store.takes.first?.assessments.last)
    store.activateEngine(.compact)
    #expect(store.preferences.activeEngine == .phone)
    #expect(requested.engine == .phone)
    store.cancelAssessments()
    #expect(store.takes.first?.assessments.last?.status == .cancelled)
  }
}

@MainActor private final class SequencePlaybackSpy {
  var targets: [ProductionPracticeTarget] = []
  var speeds: [Double] = []
  var completions: [@MainActor @Sendable () -> Void] = []
  var speedUpdates: [Double] = []
  var failure: ProductionPracticeError?

  func play(_ target: ProductionPracticeTarget, _ speed: Double,
    _ completion: @escaping @MainActor @Sendable () -> Void) throws {
    if let failure { throw failure }
    targets.append(target)
    speeds.append(speed)
    completions.append(completion)
  }

  func updateSpeed(_ speed: Double) throws {
    speedUpdates.append(speed)
  }
}
