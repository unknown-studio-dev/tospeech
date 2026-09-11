import Foundation
import Testing

@testable import EchoLab

@MainActor @Suite(.serialized)
struct PracticeLifecycleTests {
  private func store() -> EchoStore {
    EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
  }

  @Test func manualRecordingAlwaysListensFirst() {
    let store = store()
    store.practice.permission = "granted"
    store.practice.requestRecord()
    #expect(store.practice.phase == .listening)
    store.practice.sourceFinished()
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
    #expect(store.practice.phase == .listening)
    store.practice.sourceFinished()
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
    store.practice.sourceFinished()
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
    store.practice.sourceFinished()
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
    store.practice.sourceFinished()
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
    store.activateEngine(.gopt)
    #expect(store.preferences.activeEngine == .phone)
    #expect(requested.engine == .phone)
    store.cancelAssessments()
    #expect(store.takes.first?.assessments.last?.status == .cancelled)
  }
}
