import Foundation
import Testing
@testable import ToSpeech

struct SpeechPaceTests {
  @Test func syllablesComeFromIPANucleiAndFallBackToSpelling() {
    #expect(SpeechPace.syllableCount(ipa: "/pəswˈeɪdɪd/") == 3)
    #expect(SpeechPace.syllableCount(ipa: "ˈkʌntɹi") == 2)
    #expect(SpeechPace.syllableCount(ipa: "ˈaɪən") == 2)
    #expect(SpeechPace.syllableCount(ipa: "ˈbʌtɚ") == 2)
    #expect(SpeechPace.syllableCount(ipa: "ˈbɒtl̩") == 2)
    #expect(SpeechPace.syllableCount(ipa: "ˈnæʃ(ə)nəl") == 2)
    #expect(SpeechPace.syllableCount(ipa: "wɒz, wəz") == 1)
    #expect(SpeechPace.syllableCount(ipa: "ˈɡəʊɪŋ") == 2)
    #expect(SpeechPace.syllableCount(ipa: "hˈæpiə") == 3)
    #expect(SpeechPace.syllableCount(ipa: "ˈ") == nil)
    #expect(SpeechPace.syllableCount(spelling: "walked") == 1)
    #expect(SpeechPace.syllableCount(spelling: "wanted") == 2)
    #expect(SpeechPace.syllableCount(spelling: "table") == 2)
    #expect(SpeechPace.syllableCount(spelling: "make") == 1)
    #expect(SpeechPace.syllableCount(spelling: "1998") == 1)
    let word = LessonWord(id: "w", text: "persuaded", ipaUK: nil, ipaUS: "pɚˈsweɪdɪd")
    #expect(SpeechPace.syllableCount(of: word, accent: .uk) == 3)
  }

  private func sentence() -> LessonSentence {
    // Six words at 1 syllable each: four at 0.25 s (4 syl/s), one crushed to
    // 0.1 s (10 syl/s) and one stretched to 0.7 s (~1.4 syl/s), with a 0.3 s
    // pause after "was" and a 0.05 s articulation gap after "it".
    let spans: [(String, Double, Double)] = [
      ("it", 0.0, 0.25), ("was", 0.30, 0.55), ("a", 0.85, 0.95), ("long", 1.0, 1.7),
      ("day", 1.75, 2.0), ("here.", 2.05, 2.3),
    ]
    return LessonSentence(id: "s", number: 1, text: spans.map(\.0).joined(separator: " "),
      translation: "", span: AudioSpan(start: 0, end: 2.5),
      words: spans.map { LessonWord(id: $0.0, text: $0.0, ipaUK: "ə", span: AudioSpan(start: $0.1, end: $0.2)) })
  }

  @Test func wordsAreRatedAgainstTheMedianAndPausesNeedTheThreshold() throws {
    let source = sentence()
    let baseline = try #require(SpeechPace.baseline(in: [source], accent: .uk))
    #expect(baseline == 4)
    let analysis = SpeechPace.analyze(source, accent: .uk, baseline: baseline)
    #expect(analysis.words["a"]?.level == .fast)
    #expect(analysis.words["a"]?.intensity == 1)
    #expect(analysis.words["long"]?.level == .slow)
    #expect(analysis.words["it"]?.level == .even)
    #expect(analysis.words["it"]?.intensity == 0)
    #expect(analysis.words.count == 6)
    #expect(analysis.pauses.map(\.afterWordID) == ["was"])
    #expect(abs((analysis.pause(after: "was")?.duration ?? 0) - 0.3) < 1e-9)
  }

  @Test func unreliableTimingIsLeftUnmarked() {
    var source = sentence()
    source.words[2].needsTimingReview = true
    source.words[3].span = nil
    source.words[4].text = "—"
    let analysis = SpeechPace.analyze(source, accent: .uk, baseline: 4)
    #expect(analysis.words["a"] == nil)
    #expect(analysis.words["long"] == nil)
    #expect(analysis.words["day"] == nil)
    #expect(analysis.words["was"] != nil)
    #expect(analysis.pauses.isEmpty)
    #expect(SpeechPace.analyze(source, accent: .uk, baseline: nil).words.isEmpty)
    var short = sentence()
    short.words.removeLast(3)
    #expect(SpeechPace.baseline(in: [short], accent: .uk) == nil)
  }

  @Test func paceToggleDefaultsOnAndOldPreferencesDecode() throws {
    var preferences = Preferences()
    #expect(preferences.showPace)
    var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    data.removeValue(forKey: "paceHighlightVisible")
    let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(old.showPace)
    preferences.showPace = false
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(!restored.showPace)
    #expect(restored.showLinking && restored.showIPA)
  }
}
