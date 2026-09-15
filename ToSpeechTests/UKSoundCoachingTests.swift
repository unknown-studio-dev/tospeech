import Foundation
import Testing
@testable import ToSpeech

@Suite struct UKSoundCoachingTests {
  @Test func summaryNeverTreatsMissingOrPartialEvidenceAsSuccess() {
    func coverage(_ qualities: [PronunciationQuality], supported: Bool = true) -> PronunciationCoverage {
      let phones = qualities.enumerated().map { index, quality in
        PhoneDifference(id: index, kind: .scored, expected: "a", observed: nil,
          start: nil, end: nil, quality: quality)
      }
      let word = WordPronunciationEvidence(
        target: .init(id: "w", text: "fixture", variants: [], dictionarySources: [],
          sourceStart: nil, sourceEnd: nil),
        referenceIPA: nil, phones: phones, supported: supported)
      return PronunciationCoverage(.init(words: [word], duration: 1, recognizedPhones: []))
    }

    let unassessed = coverage(Array(repeating: .unassessed, count: 110))
    #expect(unassessed.assessed == 0 && unassessed.total == 110)
    #expect(unassessed.summary == .unassessed)
    #expect(unassessed.summary.symbol != "checkmark")
    #expect(coverage([]).summary == .unassessed)
    #expect(coverage([.correct], supported: false).summary == .unassessed)
    #expect(coverage([.correct, .unassessed]).summary == .partial)
    #expect(coverage([.incorrect, .unassessed]).summary == .partial)
    #expect(coverage([.correct, .nearCorrect]).summary == .focus)
    #expect(coverage([.correct, .incorrect]).summary == .focus)
    #expect(coverage([.correct, .correct]).summary == .matched)
  }

  @Test func everyRPChartSoundAndDictionaryVariantHasTeachingContent() throws {
    let consonants = ["p", "b", "t", "d", "k", "ɡ", "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h", "tʃ", "dʒ", "m", "n", "ŋ", "l", "ɹ", "j", "w"]
    #expect(UKSoundLibrary.all.count == 44)
    #expect(Set(UKSoundLibrary.all.map(\.id)).count == 44)
    for symbol in UKPhoneInventory.vowels.union(consonants).union(["ʔ", "l̩", "n̩", "m̩", "g", "r", "ɛə"]) {
      let guide = try #require(UKSoundLibrary.guide(for: symbol), "Missing guide for /\(symbol)/")
      #expect(!guide.mouth(locale: Locale(identifier: "vi")).isEmpty)
      #expect(!guide.cue(locale: Locale(identifier: "en")).isEmpty)
      #expect(guide.examples.count >= 2)
      #expect(guide.examples.allSatisfy(IPAFormatting.isPronounceable))
    }
    #expect(UKSoundLibrary.guide(for: "☃") == nil)
  }

  @Test func teachingAliasesDoNotEraseUKScoringContrasts() throws {
    // Teaching the weak vowel alongside FLEECE does not turn its evidence green.
    #expect(UKSoundLibrary.guide(for: "i")?.symbol == "iː")
    #expect(UKPhoneInventory.canonical("i") != UKPhoneInventory.canonical("iː"))
    #expect(UKPhoneInventory.canonical("ɐ") != UKPhoneInventory.canonical("ʌ"))
    #expect(UKPhoneInventory.canonical("ɒ") != UKPhoneInventory.canonical("ɑː"))
    let decision = UKReferenceQuality.decide(expected: "ɐ", supported: ["ʌ"],
      source: .init(symbol: "ʌ", probability: 1), take: .init(symbol: "ʌ", probability: 1), floor: 0.8)
    #expect(decision.quality == .unassessed)
  }

  @Test func partialCoverageSeparatesUnsupportedFromUncertainAndPreservesColors() throws {
    let phones: [PhoneDifference] = [
      .init(id: 0, kind: .scored, expected: "w", observed: nil, start: 0, end: 0.1, quality: .unassessed),
      .init(id: 1, kind: .scored, expected: "ɛ", observed: "ɛ", start: 0.1, end: 0.2, quality: .correct),
      .init(id: 2, kind: .referenceUncertain, expected: "ɪ", observed: nil, start: 0.2, end: 0.3),
      .init(id: 3, kind: .uncertain, expected: "æ", observed: nil, start: 0.3, end: 0.4)]
    let word = WordPronunciationEvidence(target: .init(id: "w", text: "fixture", variants: [], dictionarySources: [], sourceStart: nil, sourceEnd: nil), referenceIPA: nil, phones: phones, supported: true, inventory: UKPhoneInventory.version)
    let evidence = PronunciationEvidence(words: [word], duration: 1, recognizedPhones: [], qualityPolicy: UKReferenceQuality.policy)
    let before = try JSONEncoder().encode(evidence)
    let coverage = PronunciationCoverage(evidence)
    #expect(coverage.assessed == 1 && coverage.total == 4)
    #expect(coverage.reasons[.outsideModel] == 1)
    #expect(coverage.reasons[.referenceUncertain] == 1)
    #expect(coverage.reasons[.takeUncertain] == 1)
    #expect(try JSONDecoder().decode(PronunciationEvidence.self, from: before) == evidence)
    var unknown = evidence
    unknown.qualityPolicy = "future-policy"
    #expect(PronunciationCoverage(unknown).reasons[.outsideModel] == nil)
    #expect(PronunciationCoverage(unknown).reasons[.unavailable] == 1)
  }

  @Test func storedAvailabilityRoundTripsAndLegacyDecodesWithoutInventingAReason() throws {
    let legacy = try JSONDecoder().decode(PhoneDifference.self, from: Data(#"{"id":0,"kind":"scored","expected":"θ","quality":"unassessed"}"#.utf8))
    #expect(legacy.unassessedReason == nil)
    var fresh = legacy
    fresh.unassessedReason = .outsideModel
    #expect(try JSONDecoder().decode(PhoneDifference.self, from: JSONEncoder().encode(fresh)).unassessedReason == .outsideModel)
  }

  @Test func continuousUKIPAKeepsEveryPhoneClickableIncludingGreyAndMultiscalarSounds() throws {
    let units = try #require(UKPhoneInventory.parse("/ˈtʃiːzl̩/"))
    let phones = units.enumerated().map { index, unit in
      PhoneDifference(id: index, kind: .scored, expected: unit.symbol, observed: nil,
        start: Double(index)*0.1, end: Double(index+1)*0.1,
        quality: [PronunciationQuality.correct, .nearCorrect, .incorrect, .unassessed][index])
    }
    let word = WordPronunciationEvidence(target: .init(id: "word", text: "fixture", variants: [], dictionarySources: [], sourceStart: nil, sourceEnd: nil), referenceIPA: "ˈtʃiːzl̩", phones: phones, supported: true, inventory: UKPhoneInventory.version)
    let runs = PronunciationDisplay.runs(ipa: word.referenceIPA, word: word)
    #expect(runs.map(\.text).joined() == "/ˈtʃiːzl̩/")
    #expect(runs.compactMap(\.phoneID) == [0, 1, 2, 3])
    #expect(runs.filter { $0.phoneID != nil }.map(\.quality) == [.correct, .nearCorrect, .incorrect, .unassessed])
  }
}
