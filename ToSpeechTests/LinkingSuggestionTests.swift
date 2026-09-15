import Foundation
import Testing
@testable import ToSpeech

struct LinkingSuggestionTests {
  private func sentence(_ text: String = "Pick it up.") -> LessonSentence {
    LessonSentence(id: "sentence", number: 1, text: text, translation: "",
      span: AudioSpan(start: 1, end: 4), words: [
        LessonWord(id: "pick", text: "Pick", ipaUK: "pɪk", span: AudioSpan(start: 1, end: 1.5)),
        LessonWord(id: "it", text: "it", ipaUK: "/ɪt/", span: AudioSpan(start: 1.5, end: 2)),
        LessonWord(id: "up", text: "up.", ipaUK: "ʌp", span: AudioSpan(start: 2, end: 3))])
  }

  @Test func suggestsBothBoundariesAndPreservesSource() {
    let source = sentence()
    let hints = LinkingSuggestions.suggestions(in: source, accent: .uk)
    #expect(hints.map(\.phrase) == ["Pick‿it", "it‿up."])
    #expect(hints.first?.pronunciation == "/pɪk‿ɪt/")
    #expect(LinkingSuggestions.markedTranscript(source, suggestions: hints) == "Pick‿it‿up.")
    #expect(source.text == "Pick it up.")
    #expect(LinkingSuggestions.suggestions(in: source, accent: .us).isEmpty)
  }

  @Test func punctuationAndMissingOrAmbiguousIPAStopSuggestions() {
    for text in ["Pick, it up.", "Pick — it up."] {
      #expect(LinkingSuggestions.suggestions(in: sentence(text), accent: .uk).map(\.left.id) == ["it"])
    }
    var source = sentence()
    source.words[0].text = "Pick,"
    source.text = "Pick, it up."
    #expect(LinkingSuggestions.suggestions(in: source, accent: .uk).map(\.left.id) == ["it"])
    source = sentence()
    source.words[1].ipaUK = nil
    #expect(LinkingSuggestions.suggestions(in: source, accent: .uk).isEmpty)
    source.words[1].ipaUK = "(ɪ)t"
    #expect(LinkingSuggestions.suggestions(in: source, accent: .uk).isEmpty)
  }

  @Test func affricatesAndStressRemainIntact() {
    var source = sentence("Such an example.")
    source.words = [LessonWord(id: "such", text: "Such", ipaUK: "sʌtʃ"),
      LessonWord(id: "an", text: "an", ipaUK: "ən"),
      LessonWord(id: "example", text: "example.", ipaUK: "ɪɡˈzɑːmpəl")]
    let hints = LinkingSuggestions.suggestions(in: source, accent: .uk)
    #expect(hints.first?.consonant == "tʃ")
    #expect(hints.last?.pronunciation == "/ən‿ɪɡˈzɑːmpəl/")
    #expect(hints.first?.playbackSpan(in: source) == nil)
  }

  @Test func phraseUsesObservedBoundsWithoutCertifyingReview() throws {
    var source = sentence()
    source.words[0].needsTimingReview = true
    let hint = try #require(LinkingSuggestions.suggestions(in: source, accent: .uk).first)
    #expect(hint.playbackSpan(in: source) == AudioSpan(start: 1, end: 2))
    #expect(hint.left.needsTimingReview)
    for bad in [AudioSpan(start: .nan, end: 2), AudioSpan(start: 0, end: 2),
      AudioSpan(start: 2, end: 1), AudioSpan(start: 1.5, end: 5)] {
      source.words[1].span = bad
      let candidate = try #require(LinkingSuggestions.suggestions(in: source, accent: .uk).first)
      #expect(candidate.playbackSpan(in: source) == nil)
    }
  }

  @Test func oldPreferencesDecodeAndTogglePersistsIndependently() throws {
    var preferences = Preferences()
    var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    data.removeValue(forKey: "linkingSuggestionsVisible")
    let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(old.showLinking)
    preferences.showLinking = false
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(!restored.showLinking)
    #expect(restored.showIPA && restored.showTranslation)
  }
}
