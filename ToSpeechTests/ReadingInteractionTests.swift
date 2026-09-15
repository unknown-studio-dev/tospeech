import AppKit
import SwiftUI
import Testing

@testable import ToSpeech

@MainActor @Suite(.serialized)
struct ReadingInteractionTests {
  private func store() -> EchoStore {
    EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
  }

  @Test func oldPreferencesDecodeWithoutLosingOtherSettings() throws {
    var original = Preferences()
    original.speed = 1.25
    original.showIPA = false
    let data = try JSONEncoder().encode(original)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["readingSizePercent"] == nil)
    let restored = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(restored.readingPercent == 100)
    #expect(restored.speed == 1.25)
    #expect(!restored.showIPA)
    // A snapshot written before transcription-model support still decodes.
    #expect(object["activeTranscriptionModel"] == nil)
    #expect(restored.activeTranscriptionModel == nil)
  }

  @Test func activeTranscriptionModelRoundTrips() throws {
    var original = Preferences()
    original.activeTranscriptionModel = "small"
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(restored.activeTranscriptionModel == "small")
  }

  @Test func readingPreferenceClampsSnapsAndRoundTrips() throws {
    var preferences = Preferences()
    for (input, expected) in [(-5, 80), (84, 80), (115, 120), (155, 160), (500, 160)] {
      preferences.readingPercent = input
      #expect(preferences.readingPercent == expected)
    }
    preferences.readingPercent = 140
    let restored = try JSONDecoder().decode(
      Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.readingPercent == 140)
  }

  @Test func readingPreferenceDoesNotInterruptOrChangeSourceClock() {
    let store = store()
    store.practice.playSentence(repeating: true)
    store.practice.advance(by: 0.5)
    let position = store.practice.sourcePosition
    store.preferences.readingPercent = 160
    #expect(store.practice.phase == .listening)
    #expect(store.practice.sourcePosition == position)
    store.practice.phase = .recording
    store.preferences.readingPercent = 80
    #expect(store.practice.phase == .recording)
    store.practice.discardPending()
  }

  @Test func highlightUsesSourceIntervalsAndFreezesOnPause() throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    let timedWords = sentence.words.filter {
      $0.span != nil && !$0.needsTimingReview && IPAFormatting.isPronounceable($0.text)
    }
    let word = try #require(timedWords.first)
    let next = try #require(timedWords.dropFirst().first)
    let span = try #require(word.span)
    let nextSpan = try #require(next.span)
    #expect(store.practice.playingWordID(in: sentence) == nil)
    store.practice.playSentence()
    store.practice.seekSource(to: (span.start + span.end) / 2)
    #expect(store.practice.playingWordID(in: sentence) == word.id)
    store.practice.interrupt()
    #expect(store.practice.playingWordID(in: sentence) == word.id)
    store.practice.seekSource(to: min(nextSpan.start.nextDown, sentence.span.end))
    #expect(store.practice.playingWordID(in: sentence) == word.id)
    store.practice.seekSource(to: nextSpan.start)
    #expect(store.practice.playingWordID(in: sentence) == next.id)
    store.practice.phase = .recording
    #expect(store.practice.playingWordID(in: sentence) == nil)
    store.practice.discardPending()
  }

  @Test func ambiguousMissingAndHistoricalTimingNeverGetsKaraoke() throws {
    let store = store()
    var sentence = try #require(store.selectedSentence)
    let span = try #require(sentence.words[0].span)
    store.practice.playSentence()
    store.practice.seekSource(to: (span.start + span.end) / 2)
    sentence.words[0].needsTimingReview = true
    #expect(store.practice.playingWordID(in: sentence) == nil)
    sentence.words[0].needsTimingReview = false
    sentence.words[1].span = span
    #expect(store.practice.playingWordID(in: sentence) == nil)
    sentence.revision += 1
    #expect(store.practice.playingWordID(in: sentence) == nil)
    store.practice.interrupt()
  }

  @Test func referenceAndSavedTakePreviewDoNotHighlightSource() throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    store.practice.playSentence()
    store.practice.previewReference(word: sentence.words[0], accent: .us)
    #expect(store.practice.playingWordID(in: sentence) == nil)
    store.practice.playSentence()
    store.practice.previewSource(span: sentence.span, label: "Saved take")
    #expect(store.practice.playingWordID(in: sentence) == nil)
  }

  @Test func everyAssessmentAndCaptureOutcomeHasHonestInlineState() throws {
    var take = try #require(store().takes.last)
    for (status, expected): (AssessmentStatus, InlineFeedbackState) in [
      (.queued, .pending), (.running, .pending), (.complete, .complete),
      (.failed, .failed), (.cancelled, .cancelled),
    ] {
      take.assessments[0].status = status
      #expect(InlineFeedbackState(take: take) == expected)
    }
    take.assessments = []
    #expect(InlineFeedbackState(take: take) == .unscored)
    for (outcome, expected): (CaptureOutcome, InlineFeedbackState) in [
      (.noSpeech, .noSpeech), (.quiet, .quiet), (.earlyStop, .earlyStop),
      (.interrupted, .interrupted),
    ] {
      take.outcome = outcome
      #expect(InlineFeedbackState(take: take) == expected)
    }
  }

  @Test func lateAssessmentStaysFrozenDuringSpeaking() throws {
    let take = try #require(store().takes.last)
    var pending = take
    pending.assessments[0].status = .running
    var presentation = InlineFeedbackPresentation()
    presentation.refresh(candidate: pending, phase: .listening)
    for phase: PracticePhase in [.countdown, .awaitingSpeech, .recording, .trailingSilence] {
      presentation.refresh(candidate: take, phase: phase)
      #expect(presentation.take == pending)
    }
    presentation.refresh(candidate: take, phase: .listening)
    #expect(presentation.take == take)
    presentation.refresh(candidate: nil, phase: .idle)
    #expect(presentation.take == nil)
  }

  @Test func inlineFeedbackNeverUsesOtherLessonRevisionOrPhrase() throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    let take = try #require(store.takes.last)
    var changed = take
    changed.sourceSnapshot.revision += 1
    var phrase = take
    phrase.scope = .phrase
    var other = take
    other.lessonID = "another-lesson"
    #expect(
      InlineFeedbackPresentation.latest(
        in: [changed, phrase, other], lessonID: store.selectedLessonID, sentence: sentence) == nil)
    #expect(
      InlineFeedbackPresentation.latest(
        in: [take, changed, phrase, other], lessonID: store.selectedLessonID, sentence: sentence)
        == take)
  }

  @Test func completedTakeDoesNotRequestAutomaticReview() {
    let store = store()
    store.preferences.repeats = 2
    store.preferences.autoRecord = true
    store.practice.permission = "granted"
    store.practice.playSentence(repeating: true)
    store.practice.sourceFinished()
    store.practice.advance(by: 2)
    store.practice.speechDetected()
    store.practice.finishRecording()
    store.practice.commitPending()
    #expect(store.reviewTakeID == nil)
    #expect(store.practice.round == 2)
    #expect(store.practice.phase == .listening)
    store.practice.sourceFinished()
    store.practice.advance(by: 2)
    store.practice.speechDetected()
    store.practice.finishRecording()
    store.practice.commitPending()
    #expect(store.practice.phase == .feedback)
    #expect(store.reviewTakeID == nil)
    store.cancelAssessments()
  }

  @Test func sentenceHugsContentAndLargerTextReflowsWithoutScalingControls() throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    func height(_ percent: Int) -> CGFloat {
      store.preferences.readingPercent = percent
      let host = NSHostingView(
        rootView: SentenceView(
          sentence: sentence, selectedWordID: .constant(nil), onWord: { _ in }
        ).environment(store).frame(width: 752))
      return host.fittingSize.height
    }
    let normal = height(100)
    #expect(normal < 350)
    #expect(height(160) > normal)
    let popover = NSHostingView(rootView: ReadingSizePopover(percent: .constant(160)))
    #expect(popover.fittingSize.width == 320)
    #expect(popover.fittingSize.height < 300)
  }

  @Test func savedFeedbackActuallyMountsAndEmptyStateCollapses() async throws {
    let store = store()
    let sentence = try #require(store.selectedSentence)
    let host = NSHostingView(
      rootView: InlineTakeFeedback(
        sentence: sentence, onReview: { _ in }
      ).environment(store).frame(width: 900))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height > 45)
    store.takes = []
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height == 0)
  }
}
