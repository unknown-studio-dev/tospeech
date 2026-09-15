import Foundation

/// UK display/target inventory. Never use the lossy ARPAbet normalizer for new UK jobs.
enum UKPhoneInventory {
  static let version = "uk-ipa-v2"
  static let parsingPolicy = "uk-ipa-parser-v3-square"
  static func isUK(_ inventory: String?) -> Bool { inventory == version || inventory == "uk-ipa-v1" }
  struct Unit: Equatable, Sendable {
    let symbol: String
    let stress: Int
    var isVowel: Bool { UKPhoneInventory.vowels.contains(symbol) }
    var isNucleus: Bool { isVowel || ["l̩", "n̩", "m̩"].contains(symbol) }
  }
  static let vowels: Set<String> = ["iː", "ɪ", "e", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "ʊ", "uː", "ʌ", "ɐ", "ɜː", "ə", "i", "u", "eɪ", "aɪ", "ɔɪ", "əʊ", "aʊ", "ɪə", "eə", "ɛə", "ʊə", "ɛː", "ɪː", "ʊː"]
  private static let symbols = vowels.union(["p", "b", "t", "d", "k", "ɡ", "g", "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h", "tʃ", "dʒ", "m", "n", "ŋ", "l", "ɹ", "r", "j", "w", "ʔ", "l̩", "n̩", "m̩"]).sorted {
    $0.unicodeScalars.count == $1.unicodeScalars.count ? $0 < $1 : $0.unicodeScalars.count > $1.unicodeScalars.count
  }
  static func parse(_ ipa: String, inventory: String = version) -> [Unit]? {
    var rest = ipa.precomposedStringWithCanonicalMapping[...]
    var result: [Unit] = [], stress = 0
    while !rest.isEmpty {
      if rest.first == "ˈ" || rest.first == "ˌ" { stress = rest.removeFirst() == "ˈ" ? 1 : 2; continue }
      if let c = rest.first, "/[]. ‿".contains(c) { rest.removeFirst(); continue }
      // Britfone spells SQUARE /ɛə/. Historical v1 results split this sequence;
      // retain their original phone IDs while new jobs use a single nucleus.
      guard let symbol = symbols.first(where: {
        (inventory != "uk-ipa-v1" || $0 != "ɛə") && rest.hasPrefix($0)
      }) else { return nil }
      let nucleus = vowels.contains(symbol) || ["l̩", "n̩", "m̩"].contains(symbol)
      result.append(.init(symbol: symbol, stress: nucleus ? stress : 0))
      if nucleus { stress = 0 }
      rest = rest.dropFirst(symbol.count)
    }
    return result.isEmpty ? nil : result
  }
  /// Spelling aliases only; LOT/PALM, length, GOAT and rhoticity stay distinct.
  static func canonical(_ phone: String) -> String {
    switch phone { case "g": "ɡ"; case "r": "ɹ"; case "e": "ɛ"; case "ɛə": "eə"; default: phone }
  }
  static func ctcTokens(_ phone: String, vocabulary: [String: Int]) -> [Int]? {
    let normalized = canonical(phone)
    if let id = vocabulary[normalized] { return [id] }
    // This encoder has no syllabic /m̩/ token. Locate its nasal component only;
    // keep /m̩/ in the UK target and leave its syllabicity ungraded.
    if normalized == "m̩", let id = vocabulary["m"] { return [id] }
    // Some diphthongs are represented as two tokens in this specific encoder.
    if ["ɪə", "ʊə"].contains(normalized) {
      let ids = normalized.map { vocabulary[String($0)] }
      if ids.allSatisfy({ $0 != nil }) { return ids.compactMap { $0 } }
    }
    return nil
  }
}
