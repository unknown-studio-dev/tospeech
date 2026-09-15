import Foundation

struct PronunciationWordTarget: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let variants: [String]
  let dictionarySources: [String]
  let sourceStart: Double?
  let sourceEnd: Double?
}

struct RecognizedPhone: Codable, Equatable, Sendable {
  let symbol: String
  let start: Double
  let end: Double
  let posterior: Double
}

struct PhoneDifference: Codable, Equatable, Sendable, Identifiable {
  enum Kind: String, Codable, Sendable { case scored, matched, substitution, omission, insertion, uncertain, referenceUncertain }
  let id: Int
  let kind: Kind
  let expected: String?
  let observed: String?
  let start: Double?
  let end: Double?
  var quality: PronunciationQuality? = nil
  var score: Double? = nil
  var sourceScore: Double? = nil
  var scoredUnit: String? = nil
  var unassessedReason: PhoneAssessmentAvailability? = nil
}

struct WordPronunciationEvidence: Codable, Equatable, Sendable, Identifiable {
  let target: PronunciationWordTarget
  let referenceIPA: String?
  let phones: [PhoneDifference]
  let supported: Bool
  var inventory: String? = nil
  var id: String { target.id }
  var observations: [PhoneDifference] { phones.filter { $0.kind != .matched && ($0.kind != .scored || $0.quality != .correct) } }
  var differences: [PhoneDifference] { observations.filter { $0.kind != .referenceUncertain && $0.quality != .unassessed } }
}

struct PronunciationEvidence: Codable, Equatable, Sendable {
  let words: [WordPronunciationEvidence]
  let duration: Double
  let recognizedPhones: [RecognizedPhone]
  var referencePhones: [RecognizedPhone]? = nil
  var qualityPolicy: String? = nil
  var audioDecodingPolicy: String? = nil
  var delivery: DeliveryEvidence? = nil
  var ukReference: UKReferenceEvidence? = nil
  var phoneticXeus: PhoneticXeusEvidence? = nil
  var assessedWords: Int { words.filter { $0.supported && !$0.phones.contains(where: { $0.kind == .referenceUncertain }) }.count }
  var changedWords: Int { words.filter { $0.supported && !$0.differences.isEmpty }.count }
}

/// Inventory comparison, not an accent/prosody grade. Full IPA variants remain
/// in the result; normalization only merges contrasts this recognizer cannot measure.
enum PhoneInventory {
  static let arpabet: [String: String] = [
    "AA":"ɑ", "AE":"æ", "AH":"ʌ", "AO":"ɔ", "AW":"aʊ", "AY":"aɪ", "B":"b",
    "CH":"tʃ", "D":"d", "DH":"ð", "EH":"ɛ", "ER":"ɝ", "EY":"eɪ", "F":"f",
    "G":"ɡ", "HH":"h", "IH":"ɪ", "IY":"i", "JH":"dʒ", "K":"k", "L":"l",
    "M":"m", "N":"n", "NG":"ŋ", "OW":"oʊ", "OY":"ɔɪ", "P":"p", "R":"ɹ",
    "S":"s", "SH":"ʃ", "T":"t", "TH":"θ", "UH":"ʊ", "UW":"u", "V":"v",
    "W":"w", "Y":"j", "Z":"z", "ZH":"ʒ"]

  static func fromARPAbet(_ token: String) -> String? {
    // Star/deletion/composite labels are not documented ordinary phones.
    guard !token.contains("*") else { return nil }
    if token == "AH0" { return "ə" }
    if token == "ER0" { return "ɚ" }
    return arpabet[token.filter { !$0.isNumber }]
  }

  static func canonical(_ phone: String) -> String {
    switch phone {
    case "ɒ": "ɑ"
    case "əʊ": "oʊ"
    case "r": "ɹ"
    case "g": "ɡ"
    case "ɚ": "ɝ"
    case "e": "ɛ"
    default: phone
    }
  }

  static func parse(_ ipa: String) -> [String]? {
    let cleaned = ipa.filter { !"/[]ˈˌːˑ. ".contains($0) }
    let inventory = Set(arpabet.values).union(["ə", "ɚ", "ɒ", "əʊ", "r", "g", "e"])
      .sorted { $0.count > $1.count }
    var remaining = cleaned[...], phones: [String] = []
    while !remaining.isEmpty {
      guard let token = inventory.first(where: { remaining.hasPrefix($0) }) else { return nil }
      phones.append(token)
      remaining = remaining.dropFirst(token.count)
    }
    return phones.isEmpty ? nil : phones
  }
}
