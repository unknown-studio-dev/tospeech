import Foundation
import Testing

@testable import ToSpeech

struct TimingRulesTests {
  @Test func invalidWordDraftSurvivesEditingAnotherWordAndBlocksSaveAtItsOwnTarget() throws {
    var drafts = TimingInputDrafts()
    drafts[.word("w1")].edit("1", isStart: false)
    drafts[.word("w2")].edit("2,5", isStart: false)
    #expect(drafts[.word("w1")].end == "1")
    #expect(drafts.isDirty)
    let result = drafts.applying(to: fixture, duration: 10, locale: Locale(identifier: "vi_VN"))
    guard case .failure(let failure) = result else {
      Issue.record("A hidden invalid word must block saving, not be silently discarded")
      return
    }
    #expect(failure.target == .word("w1"))
    #expect(fixture.words[1].span?.end == 2.2)
    #expect(drafts[.word("w2")].end == "2,5")

    drafts[.word("w1")].edit("1,4", isStart: false)
    let saved = try drafts.applying(to: fixture, duration: 10, locale: Locale(identifier: "vi_VN")).get()
    #expect(saved.words[0].span == AudioSpan(start: 1, end: 1.4))
    #expect(saved.words[1].span == AudioSpan(start: 1.5, end: 2.5))
  }

  @Test func adjacentWordCorrectionsValidateTogetherAgainstTheirNewBoundaries() throws {
    var drafts = TimingInputDrafts()
    // The first correction overlaps the old second word, but not its new start.
    drafts[.word("w1")].edit("1.7", isStart: false)
    drafts[.word("w2")].edit("1.7", isStart: true)
    let saved = try drafts.applying(to: fixture, duration: 10, locale: Locale(identifier: "en_US")).get()
    #expect(saved.words[0].span?.end == 1.7)
    #expect(saved.words[1].span?.start == 1.7)
    #expect(TimingRules.validate(saved, duration: 10) == nil)
  }

  @Test func incompleteUnalignedInputRemainsPendingWhileOtherTargetsAreEdited() throws {
    var sentence = fixture
    sentence.words[0].span = nil
    var drafts = TimingInputDrafts()
    drafts[.word("w1")].edit("", isStart: true)
    drafts[.sentence].edit("3,5", isStart: false)
    guard case .failure(let failure) = drafts.applying(to: sentence, duration: 10,
      locale: Locale(identifier: "vi_VN")) else {
      Issue.record("An incomplete unaligned word must remain an editable draft")
      return
    }
    #expect(failure.target == .word("w1"))
    #expect(drafts[.word("w1")].start == "")
    drafts[.word("w1")].edit("1,1", isStart: true)
    drafts[.word("w1")].edit("1,4", isStart: false)
    let saved = try drafts.applying(to: sentence, duration: 10, locale: Locale(identifier: "vi_VN")).get()
    #expect(saved.span.end == 3.5)
    #expect(saved.words[0].span == AudioSpan(start: 1.1, end: 1.4))
  }

  @Test func draftsKeepMoveIntentAndIdentifyExistingBrokenWord() throws {
    var drafts = TimingInputDrafts()
    drafts[.sentence].edit("4", isStart: true)
    drafts[.sentence].movesRange = true
    let moved = try drafts.applying(to: fixture, duration: 10, locale: Locale(identifier: "en_US")).get()
    #expect(moved.span == AudioSpan(start: 4, end: 6))
    #expect(moved.words[0].span == AudioSpan(start: 4, end: 4.5))

    var broken = fixture
    broken.words[0].span = AudioSpan(start: 1.5, end: 1.5)
    guard case .failure(let failure) = TimingInputDrafts().applying(to: broken, duration: 10,
      locale: Locale(identifier: "en_US")) else {
      Issue.record("Saving should identify an existing zero-duration word")
      return
    }
    #expect(failure.target == .word("w1"))
  }

  @Test func transcriptChangesDiscardOnlyDraftsForDeletedWords() {
    var drafts = TimingInputDrafts()
    drafts[.word("w1")].edit("-", isStart: true)
    drafts[.word("w2")].edit("2.5", isStart: false)
    drafts[.sentence].edit("3.5", isStart: false)
    drafts.retainWords(["w2"])
    #expect(!drafts[.word("w1")].isDirty)
    #expect(drafts[.word("w2")].end == "2.5")
    #expect(drafts[.sentence].end == "3.5")
    #expect(drafts.isDirty)
  }

  @Test func pendingTimingFieldsResolveWithoutSubmitOrFocusChange() {
    let stored = AudioSpan(start: 118, end: 118.4)
    let bounds = AudioSpan(start: 116, end: 120)
    var input = TimingNumericInput()
    input.edit("117", isStart: false)
    #expect(input.resolve(span: stored, bounds: bounds, moving: false) == nil)
    // Both fields can be corrected even when the intermediate pair is invalid.
    input.edit("116.5", isStart: true)
    #expect(input.resolve(span: stored, bounds: bounds, moving: false)
      == AudioSpan(start: 116.5, end: 117))
    #expect(stored == AudioSpan(start: 118, end: 118.4))
  }

  @Test func pendingTimingNeverFallsBackToOldRangeForInvalidText() {
    let span = AudioSpan(start: 118, end: 118.4)
    for text in ["", "-", "abc", "nan", "inf", "118", "121"] {
      var input = TimingNumericInput()
      input.edit(text, isStart: false)
      #expect(input.resolve(span: span, bounds: AudioSpan(start: 116, end: 120), moving: false) == nil)
      #expect(input.end == text)
      #expect(input.isDirty)
    }
  }

  @Test func pendingTimingPreservesUntouchedPrecisionAndLocale() {
    var input = TimingNumericInput()
    input.edit("118,75", isStart: false)
    #expect(input.resolve(span: AudioSpan(start: 118.123456, end: 118.5),
      bounds: AudioSpan(start: 116, end: 120), moving: false, locale: Locale(identifier: "vi_VN"))
      == AudioSpan(start: 118.123456, end: 118.75))
  }

  @Test func pendingMoveUsesLastEditedEdgeAndKeepsDuration() {
    var input = TimingNumericInput()
    input.edit("3", isStart: true)
    let span = AudioSpan(start: 2, end: 4)
    let bounds = AudioSpan(start: 0, end: 10)
    #expect(input.resolve(span: span, bounds: bounds, moving: true) == AudioSpan(start: 3, end: 5))
    input.edit("7", isStart: false)
    #expect(input.resolve(span: span, bounds: bounds, moving: true) == AudioSpan(start: 5, end: 7))
    input.edit("11", isStart: false)
    #expect(input.resolve(span: span, bounds: bounds, moving: true) == nil)
  }

  @Test func rejectsBlankTranscriptAndOverlaps() {
    var sentence = fixture
    sentence.text = "  "
    #expect(TimingRules.validate(sentence, duration: 10) == "English transcript is required.")
    sentence = fixture
    sentence.words[1].span = AudioSpan(start: 1.4, end: 2.2)
    #expect(TimingRules.validate(sentence, duration: 10) == "Word timings cannot overlap.")
  }

  @Test func allowsUnalignedNewWordsButPreservesKnownWords() {
    let words = TimingRules.reconcile(
      text: "Hello brave world", sentenceID: fixture.id, candidates: fixture.words)
    #expect(words.map(\.id) == ["w1", "s1-edited-word-1", "w2"])
    #expect(words[0].span == fixture.words[0].span)
    #expect(words[1].span == nil)
    #expect(words[1].needsTimingReview)
    var sentence = fixture
    sentence.text = "Hello brave world"
    sentence.words = words
    #expect(TimingRules.validate(sentence, duration: 10) == nil)
  }

  @Test func generatedIDsNeverCollideWithMovedEditedWords() {
    let first = TimingRules.reconcile(text: "foo", sentenceID: "s1", candidates: [])
    let second = TimingRules.reconcile(text: "bar foo", sentenceID: "s1", candidates: first)
    #expect(Set(second.map(\.id)).count == 2)
    #expect(second[1].id == first[0].id)
  }

  @Test func zeroLengthMatchedWordsRemainUnverified() {
    let candidate = LessonWord(
      id: "w", text: "word", ipaUK: nil, ipaUS: nil,
      span: AudioSpan(start: 1, end: 1), needsTimingReview: false)
    let result = TimingRules.reconcile(text: "word", sentenceID: "s", candidates: [candidate])
    #expect(result[0].needsTimingReview)
  }

  @Test func shiftingMovesEveryKnownSpanAndPreservesUnknowns() {
    var sentence = fixture
    sentence.words.append(
      LessonWord(id: "new", text: "new", ipaUK: nil, ipaUS: nil, span: nil, needsTimingReview: true)
    )
    let shifted = TimingRules.shifted(sentence, by: 1, duration: 10)
    #expect(shifted?.span == AudioSpan(start: 2, end: 4))
    #expect(shifted?.words[0].span == AudioSpan(start: 2, end: 2.5))
    #expect(shifted?.words[2].span == nil)
    #expect(TimingRules.shifted(sentence, by: -2, duration: 10) == nil)
  }

  @Test func numericMoveUsesTheEditedBoundary() {
    let span = AudioSpan(start: 2, end: 4)
    let limits = AudioSpan(start: 0, end: 10)
    #expect(
      TimingRules.moved(span, matchingStart: true, to: 3, limits: limits)
        == AudioSpan(start: 3, end: 5))
    #expect(
      TimingRules.moved(span, matchingStart: false, to: 6, limits: limits)
        == AudioSpan(start: 4, end: 6))
    #expect(TimingRules.moved(span, matchingStart: false, to: 11, limits: limits) == nil)
  }

  @Test func repeatedWordsKeepDeterministicOrderAndReordersLoseUnsafeSpan() {
    let repeated = [
      LessonWord(id: "a", text: "the", ipaUK: nil, ipaUS: nil, span: AudioSpan(start: 1, end: 1.2)),
      LessonWord(
        id: "b", text: "the", ipaUK: nil, ipaUS: nil, span: AudioSpan(start: 1.2, end: 1.4)),
    ]
    #expect(
      TimingRules.reconcile(text: "the the", sentenceID: "s", candidates: repeated).map(\.id) == [
        "a", "b",
      ])
    let reordered = TimingRules.reconcile(
      text: "world Hello", sentenceID: fixture.id, candidates: fixture.words)
    #expect(reordered[0].id == "w2")
    #expect(reordered[1].id == "w1")
    #expect(reordered[1].span == nil)
    #expect(reordered[1].needsTimingReview)
  }

  private var fixture: LessonSentence {
    LessonSentence(
      id: "s1", number: 1, text: "Hello world", translation: "Xin chào",
      span: AudioSpan(start: 1, end: 3),
      words: [
        LessonWord(
          id: "w1", text: "Hello", ipaUK: "/həˈləʊ/", ipaUS: nil,
          span: AudioSpan(start: 1, end: 1.5)),
        LessonWord(
          id: "w2", text: "world", ipaUK: "/wɜːld/", ipaUS: nil,
          span: AudioSpan(start: 1.5, end: 2.2)),
      ])
  }
}
