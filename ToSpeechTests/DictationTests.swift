import Foundation
import Testing
@testable import ToSpeech

@MainActor struct DictationTests {
  final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

  @Test func clickingSentencePlaysIncludingCurrentRowAndIgnoresPreviousCompletion() async throws {
    let audio = DictationPreviewAudio()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio)
    let sentences = try DictationFixtures.sentences()
    await model.activate(sentences)
    defer { model.suspend() }
    #expect(audio.played.isEmpty)
    model.selectAndListen(sentences[0].id)
    #expect(audio.played.last == sentences[0].target)
    #expect(model.phase == .listening)
    #expect(!model.canEdit)
    let previousCompletion = audio.completion
    model.selectAndListen(sentences[1].id)
    #expect(audio.played.last == sentences[1].target)
    previousCompletion?()
    #expect(!model.canEdit)
    audio.finish()
    #expect(model.canEdit)
    #expect(model.current?.draft.listenCount == 1)
    model.selectAndListen(UUID())
    #expect(audio.played.count == 2)
  }

  @Test func settingsSeedTheLimitUntilTheLearnerPicksOneThisSession() async throws {
    let model = DictationModel(storage: DictationMemoryStorage(), player: DictationPreviewAudio())
    #expect(model.nextTimeLimit == 25)
    model.applyPreferredLimit(nil)
    #expect(model.nextTimeLimit == nil)
    #expect(model.lastTimedLimit == 25)
    model.applyPreferredLimit(60)
    #expect(model.nextTimeLimit == 60)
    #expect(model.lastTimedLimit == 60)
    model.applyPreferredLimit(7)
    #expect(model.nextTimeLimit == 60, "Values outside the offered limits are ignored")

    let sentences = try DictationFixtures.sentences()
    await model.activate(sentences)
    defer { model.suspend() }
    #expect(model.displayedTimeLimit == 60)
    model.setLimit(45)
    model.applyPreferredLimit(15)
    #expect(model.nextTimeLimit == 45, "A choice made in this session wins over Settings")
    #expect(model.current?.draft.timeLimit == 45)
  }

  @Test func rowReplayAndResumePreserveAnswerAndRemainingTime() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    let sentences = try DictationFixtures.sentences()
    await model.activate(sentences)
    defer { model.suspend() }
    model.selectAndListen(sentences[0].id); audio.finish()
    model.edit("my draft"); clock.date += 5; model.tick()
    model.selectAndListen(sentences[0].id)
    clock.date += 2; model.tick(); audio.finish()
    #expect(model.remainingSeconds == 18)
    model.suspend(); clock.date += 60
    model.selectAndListen(sentences[0].id)
    #expect(model.isPlaying)
    #expect(!model.isPaused)
    #expect(model.remainingSeconds == 18)
    #expect(model.current?.draft.answer == "my draft")
    clock.date += 1; model.tick(); audio.finish()
    #expect(model.remainingSeconds == 17)
    model.submit()
    let saved = model.current?.attempts
    model.selectAndListen(sentences[0].id); audio.finish()
    #expect(model.phase == .result)
    #expect(model.current?.attempts == saved)
  }

  @Test func fullListenUnlocksInputOnceAndReplayKeepsDeadline() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.edit("early"); model.submit()
    #expect(model.current?.draft.answer == "")
    #expect(model.current?.attempts.isEmpty == true)
    model.play()
    #expect(model.phase == .listening)
    clock.date += 100
    model.tick()
    #expect(model.remainingSeconds == 25)
    audio.finish(); audio.finish()
    #expect(model.phase == .writing)
    #expect(model.current?.draft.listenCount == 1)
    clock.date += 5; model.tick()
    model.play(); audio.finish()
    #expect(model.remainingSeconds == 20)
    #expect(model.current?.draft.listenCount == 2)
    model.edit("I never thought it would make such a")
    model.submit(); model.submit()
    #expect(model.attempt?.matchedCount == 8)
    #expect(model.attempt?.targetCount == 9)
    #expect(model.attempt?.comparison.differences == [.init(kind: .missing, expected: "difference", observed: nil)])
    #expect(model.current?.attempts.count == 1)
    await model.flush()
    #expect(model.saveError == nil)
  }

  @Test func interruptedListenAndLateCallbacksNeverUnlockAnotherSentence() async throws {
    let audio = DictationPreviewAudio()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio)
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.play(); let oldCompletion = audio.completion
    model.stopPlayback(); oldCompletion?()
    #expect(model.phase == .ready)
    model.play(); let second = audio.completion
    model.step(1); second?()
    #expect(model.phase == .ready)
    #expect(model.current?.draft.hasListened == false)
    model.play(); audio.onFailure?("Audio unavailable"); audio.finish()
    #expect(model.error == "Audio unavailable")
    #expect(model.current?.draft.hasListened == false)
  }

  @Test func pauseAndReopenRetainTimeAndRequireExplicitResume() async throws {
    let audio = DictationPreviewAudio(), clock = Clock(), storage = DictationMemoryStorage()
    let sentences = try DictationFixtures.sentences()
    let model = DictationModel(storage: storage, player: audio, now: { clock.date })
    await model.activate(sentences)
    model.play(); audio.finish(); model.edit("I never thought")
    clock.date += 7; model.suspend(); await model.flush()
    #expect(model.remainingSeconds == 18)
    clock.date += 120; model.tick()
    #expect(model.remainingSeconds == 18)
    let restored = DictationModel(storage: storage, player: DictationPreviewAudio(), now: { clock.date })
    await restored.activate(sentences)
    defer { restored.suspend() }
    #expect(restored.phase == .paused)
    #expect(restored.current?.draft.answer == "I never thought")
    #expect(restored.remainingSeconds == 18)
    restored.play()
    #expect(!restored.isPlaying)
    restored.resume(); clock.date += 18; restored.tick()
    #expect(restored.phase == .result)
    #expect(restored.attempt?.timedOut == true)
    #expect(restored.attempt?.answer == "I never thought")
  }

  @Test func expirySubmitsBlankExactlyOnceWithoutAdvancing() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    let id = model.selectedID
    model.setLimit(15); model.play(); audio.finish()
    model.setLimit(60)
    #expect(model.nextTimeLimit == 15)
    clock.date += 16
    model.tick(); model.tick(); model.edit("late input"); model.submit()
    #expect(model.selectedID == id)
    #expect(model.current?.attempts.count == 1)
    #expect(model.attempt?.timedOut == true)
    #expect(model.attempt?.answer == "")
    #expect(model.attempt?.matchedCount == 0)
    #expect(model.attempt?.comparison.words.allSatisfy { $0.kind == .missing } == true)
    await model.flush()
  }

  @Test func untimedRetryKeepsHistoryAndNormalizesCaseAndPunctuation() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    model.setLimit(nil); model.play(); audio.finish()
    clock.date += 1_000; model.tick()
    #expect(model.phase == .writing)
    #expect(model.remainingSeconds == nil)
    model.edit("I NEVER thought it would make such a difference!"); model.submit()
    let first = model.attempt
    #expect(first?.isExact == true)
    model.setLimit(45); model.retrySentence()
    #expect(model.current?.latest == first)
    #expect(model.phase == .ready)
    #expect(model.remainingSeconds == 45)
    #expect(model.current?.draft.answer == "")
    model.submit()
    #expect(model.current?.attempts.count == 1)
    model.play(); audio.finish(); model.edit("a difference"); model.submit()
    #expect(model.current?.attempts.count == 2)
    model.selectedAttemptID = first?.id
    #expect(model.attempt == first)
    await model.flush()
    #expect(model.saveError == nil)
  }

  @Test func failedSaveRetainsLatestDraftAndRetryPersistsIt() async throws {
    let audio = DictationPreviewAudio(), storage = DictationMemoryStorage()
    let model = DictationModel(storage: storage, player: audio)
    let sentences = try DictationFixtures.sentences()
    await model.activate(sentences)
    await storage.setFailure(true)
    model.play(); audio.finish(); model.edit("old"); model.edit("newest draft")
    model.suspend(); await model.flush()
    #expect(model.saveError != nil)
    await storage.setFailure(false)
    await model.activate(sentences)
    #expect(model.current?.draft.answer == "newest draft")
    model.retrySave(); await model.flush()
    #expect(model.saveError == nil)
    #expect(try await storage.dictationProgress(lessonID: sentences[0].target.lessonID).first?.draft.answer == "newest draft")
  }

  @Test func switchingSentencesKeepsIndependentDraftsAndNewRevisionStartsFresh() async throws {
    let audio = DictationPreviewAudio(), storage = DictationMemoryStorage()
    let model = DictationModel(storage: storage, player: audio)
    let sentences = try DictationFixtures.sentences()
    await model.activate(sentences)
    model.play(); audio.finish(); model.edit("first draft")
    model.step(1); model.play(); audio.finish(); model.edit("second draft")
    model.step(-1)
    #expect(model.current?.draft.answer == "first draft")
    #expect(model.phase == .paused)
    await model.flush()
    let revised = ProductionPreparedSentence(target: .init(lessonID: sentences[0].target.lessonID,
      lessonGeneration: 1, segmentID: sentences[0].target.segmentID, segmentRevisionID: UUID(),
      audioAssetID: sentences[0].target.audioAssetID, audioURL: sentences[0].target.audioURL,
      sampleRate: 16_000, startFrame: 0, endFrame: 64_000, text: "Updated sentence",
      scope: .sentence, wordIDs: []), revision: 2, tokens: [], baseline: sentences[0].baseline, annotations: [])
    await model.activate([revised])
    #expect(model.phase == .ready)
    #expect(model.current?.draft.answer == "")
    #expect(model.progress[sentences[0].id]?.draft.answer == "first draft")
    model.suspend()
  }

  @Test func limitChoiceIsKeptWhileRevisitingFinishedSentences() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.setLimit(nil); model.play(); audio.finish(); model.submit()
    #expect(model.phase == .result)
    model.setLimit(45)
    #expect(model.displayedTimeLimit == 45)
    model.step(1)
    #expect(model.current?.draft.timeLimit == 45)
    #expect(model.remainingSeconds == 45)
    model.step(-1)
    #expect(model.nextTimeLimit == 45)
    #expect(model.displayedTimeLimit == 45)
    model.setLimit(nil)
    model.step(1)
    #expect(model.current?.draft.timeLimit == nil)
    #expect(model.remainingSeconds == nil)
    model.play(); audio.finish()
    model.step(1); model.setLimit(15)
    #expect(model.current?.draft.timeLimit == 15)
    model.step(-1)
    #expect(model.phase == .paused)
    #expect(model.displayedTimeLimit == nil)
    #expect(model.nextTimeLimit == 15)
    #expect(!model.canChangeLimit)
  }

  @Test func transportPlayResumesAPausedSentenceAndReplays() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.play(); audio.finish(); model.edit("draft")
    clock.date += 5; model.suspend()
    #expect(model.phase == .paused)
    model.listen()
    #expect(!model.isPaused)
    #expect(model.isPlaying)
    #expect(model.phase == .writing)
    #expect(model.remainingSeconds == 20)
    audio.finish()
    #expect(model.current?.draft.listenCount == 2)
    #expect(model.current?.draft.answer == "draft")
  }

  @Test func clockTicksLeaveTheDraftUntouchedUntilSaveOrSubmit() async throws {
    let audio = DictationPreviewAudio(), clock = Clock()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio, now: { clock.date })
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.play(); audio.finish()
    let before = model.progress
    clock.date += 3; model.tick()
    #expect(model.remainingSeconds == 22)
    #expect(model.progress == before)
    model.suspend()
    #expect(model.current?.draft.remainingSeconds == 22)
    model.resume(); clock.date += 22; model.tick()
    #expect(model.phase == .result)
    #expect(model.attempt?.timedOut == true)
  }

  @Test func switchingBackToTimedRestoresTheLastTimedLimit() async throws {
    let model = DictationModel(storage: DictationMemoryStorage(), player: DictationPreviewAudio())
    try await model.activate(DictationFixtures.sentences())
    defer { model.suspend() }
    model.setLimit(60); model.setLimit(nil)
    #expect(model.lastTimedLimit == 60)
    #expect(model.displayedTimeLimit == nil)
    model.setLimit(model.lastTimedLimit)
    #expect(model.current?.draft.timeLimit == 60)
    #expect(model.remainingSeconds == 60)
  }
}
