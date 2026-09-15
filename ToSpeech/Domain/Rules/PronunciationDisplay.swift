import Foundation

enum PronunciationQuality: String, Codable, Sendable, CaseIterable {
  case correct, nearCorrect, incorrect, unassessed
}

/// A versioned phoneme-category comparison, not a calibrated pronunciation score.
/// Posterior uncertainty is handled before this policy and never means near-correct.
enum PronunciationQualityPolicy {
  static let version = "phone-category-v1"
  static func quality(for phone: PhoneDifference) -> PronunciationQuality {
    switch phone.kind {
    case .uncertain, .referenceUncertain: return .unassessed
    case .matched: return .correct
    case .scored: return phone.quality ?? .unassessed
    case .omission, .insertion: return .incorrect
    case .substitution:
      guard let expected = phone.expected, let observed = phone.observed else { return .unassessed }
      let pair = Set([PhoneInventory.canonical(expected), PhoneInventory.canonical(observed)])
      // Neighboring vowel categories or a voicing-only consonant contrast.
      // The recognized category still differs; show the actual pair in details.
      let neighbors = ["i ɪ", "u ʊ", "ɛ æ", "ə ʌ", "ɑ ɔ", "p b", "t d", "k ɡ", "f v", "s z", "θ ð", "ʃ ʒ", "tʃ dʒ"]
      return neighbors.contains { Set($0.split(separator: " ").map(String.init)) == pair } ? .nearCorrect : .incorrect
    }
  }
}

struct PronunciationDisplayRun: Equatable, Identifiable {
  let id: Int
  let text: String
  let phoneID: Int?
  let quality: PronunciationQuality
}

enum PronunciationDisplay {
  static func quality(_ phone: PhoneDifference, supported: Bool) -> PronunciationQuality {
    guard supported, phone.kind != .uncertain, phone.kind != .referenceUncertain else { return .unassessed }
    // Historical jobs retain their original category; do not retroactively apply a new policy.
    return phone.quality ?? (phone.kind == .scored ? .unassessed : phone.kind == .matched ? .correct : .incorrect)
  }

  static func runs(ipa: String?, word: WordPronunciationEvidence?) -> [PronunciationDisplayRun] {
    guard let formatted = IPAFormatting.display(ipa) else { return [] }
    let expected = UKPhoneInventory.isUK(word?.inventory)
      ? UKPhoneInventory.parse(formatted, inventory: word!.inventory!)?.map(\.symbol) : PhoneInventory.parse(formatted)
    guard let expected, let word,
      word.phones.compactMap(\.expected) == expected else {
      return [.init(id: 0, text: formatted, phoneID: nil, quality: .unassessed)]
    }
    let phones = word.phones.filter { $0.expected != nil }
    var remaining = formatted[...], index = 0, output: [PronunciationDisplayRun] = []
    while !remaining.isEmpty {
      if index < phones.count, let expected = phones[index].expected, remaining.hasPrefix(expected) {
        let phone = phones[index]
        output.append(.init(id: output.count, text: expected, phoneID: phone.id,
          quality: quality(phone, supported: word.supported)))
        remaining = remaining.dropFirst(expected.count)
        index += 1
      } else {
        // Slashes, stress and length notation remain readable without claiming measurement.
        output.append(.init(id: output.count, text: String(remaining.removeFirst()), phoneID: nil, quality: .unassessed))
      }
    }
    for phone in word.phones where phone.expected == nil {
      output.append(.init(id: output.count, text: " +\(phone.observed ?? "?")", phoneID: phone.id,
        quality: quality(phone, supported: word.supported)))
    }
    return output
  }
}
