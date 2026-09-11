import Testing

@testable import EchoLab

struct TimingRulesTests {
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
