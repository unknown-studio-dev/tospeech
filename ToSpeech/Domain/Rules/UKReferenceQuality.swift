import Foundation

/// An explicit teaching policy over confidently identified vowel categories.
/// It is not a learned severity scale. Confidence never means "near correct".
enum UKReferenceQuality {
  static let policy = "uk-vowel-neighbours-v1-experimental"
  struct Decision {
    let kind: PhoneDifference.Kind
    let quality: PronunciationQuality
    let observed: String?
  }
  static func decide(expected: String, supported: [String], source: UKVowelPrediction?,
    take: UKVowelPrediction?, floor: Double) -> Decision {
    let expected = UKPhoneInventory.canonical(expected)
    guard supported.contains(expected) else { return .init(kind: .scored, quality: .unassessed, observed: nil) }
    guard let source, source.symbol == expected, source.probability >= floor else {
      return .init(kind: .referenceUncertain, quality: .unassessed, observed: nil)
    }
    guard let take, take.probability >= floor, supported.contains(take.symbol) else {
      return .init(kind: .uncertain, quality: .unassessed, observed: nil)
    }
    // Adjacent short-front vowel categories; UK LOT/PALM and vowel length are
    // deliberately NOT collapsed or treated as an automatic near match.
    let pair = Set([expected, take.symbol])
    let neighbouring = pair == Set(["ɪ", "ɛ"]) || pair == Set(["ɛ", "æ"])
    return .init(kind: .scored, quality: take.symbol == expected ? .correct : neighbouring ? .nearCorrect : .incorrect,
      observed: take.symbol)
  }
}
