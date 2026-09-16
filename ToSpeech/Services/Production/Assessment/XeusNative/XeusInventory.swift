import Foundation

/// UK CTC evidence tables — a 1:1 port of `scripts/assessment/phoneticxeus/evidence.py` lines
/// 6-43 (tables) and 52-94/175-192 (`encode`/`accepted`/`conditional`/`pair_realizations`/
/// `build_units`), mapping revision `xeus-uk-inventory-v4`.
///
/// UK CTC evidence, not calibrated pronunciation accuracy on its own — see `XeusAssess`/
/// `XeusRuntime` (later tasks) for the decision policy built on top of this inventory.
enum XeusInventory {
  static let mapping = "xeus-uk-inventory-v4"

  /// Hashable substitute for Python's `(str, str)` tuple used as a `PAIRS`/`CONDITIONAL`-style key.
  struct PhonePair: Hashable {
    let first: String
    let second: String
    init(_ first: String, _ second: String) {
      self.first = first
      self.second = second
    }
  }

  // These are tokenization/spelling alternatives, never LOT/PALM or rhoticity merges.
  static let DIPHTHONGS: [String: [String]] = [
    "ɛə": ["ɛ", "ə"], "eɪ": ["e", "ɪ"], "aɪ": ["a", "ɪ"], "ɔɪ": ["ɔ", "ɪ"], "əʊ": ["ə", "ʊ"],
    "aʊ": ["a", "ʊ"], "ɪə": ["ɪ", "ə"], "eə": ["ɛ", "ə"], "ʊə": ["ʊ", "ə"],
  ]

  static let UK: [String] = [
    "iː", "ɪ", "e", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "ʊ", "uː", "ʌ", "ɐ", "ɜː", "ə", "i", "u", "eɪ",
    "aɪ", "ɔɪ", "əʊ", "aʊ", "ɪə", "eə", "ʊə", "ɛː", "ɪː", "ʊː", "p", "b", "t", "d", "k", "ɡ", "f",
    "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h", "tʃ", "dʒ", "m", "n", "ŋ", "l", "ɹ", "j", "w", "ʔ",
    "l̩", "n̩", "m̩",
  ]

  /// `UK[:27]` in Python — the vowel/diphthong phones; used by `accepted`'s nasal-alternative rule.
  private static let ukVowelPrefix: Set<String> = Set(UK.prefix(27))

  // Class A/B/C — label conventions of this recognizer on English, measured on native RP audio
  // (0 length marks in 704 tokens; GOAT always [o ʊ]; initial /b d g/ emitted as unaspirated [p t k]).
  // Contrasts survive because quality tokens differ: ɪ/i/iː, ʊ/u/uː, ɒ/ɑ/ɑː, ɔ/ɔː, ʌ, ɜ/ə are distinct ids.
  static let LENGTHLESS: [String: String] = [
    "iː": "i", "uː": "u", "ɑː": "ɑ", "ɔː": "ɔ", "ɜː": "ɜ", "ɛː": "ɛ", "ɪː": "ɪ", "ʊː": "ʊ",
  ]
  static let GOAT: [String: [[String]]] = ["əʊ": [["o", "ʊ"]]]
  static let DEVOICED: [String: String] = ["b": "p", "d": "t", "g": "k", "ɡ": "k"]
  static let ASPIRATED: [String: String] = ["p": "pʰ", "t": "tʰ", "k": "kʰ"]

  // Class D — accent/speaker-dependent realizations. NEVER accepted globally: runtime Stage A
  // licenses one of these for one unit only when the reference audio realized it there.
  static let CONDITIONAL: [String: [[String]]] = [
    "ɛə": [["ɛ", "ɹ"], ["e", "ɹ"], ["ɛ", "ə", "ɹ"], ["ɛ"], ["e"]],
    "eə": [["ɛ", "ɹ"], ["e", "ɹ"], ["ɛ"], ["e"]],
    "ɪə": [["ɪ", "ɹ"], ["i", "ɹ"], ["ɪ"], ["i"], ["i", "ə"], ["ɪ", "ə"], ["j", "ə"]],
    "ʊə": [["ʊ", "ɹ"], ["u", "ɹ"], ["ʊ"], ["u", "ə"], ["ʊ", "ə"]],
    "ɑː": [["ɑ", "ɹ"]],
    "ɔː": [["ɔ", "ɹ"], ["ʊ", "ɹ"], ["ʊ", "ə"], ["o", "ɹ"], ["o"]],
    "ɜː": [["ɜ˞"], ["ə˞"], ["ɜ", "ɹ"]],
    "ə": [["ɜ˞"], ["ə˞"], ["ɐ"], ["ʌ"], ["ɪ"], ["ʊ"], ["ɜ"]],
    "ɐ": [["ʌ"], ["ə"]], "ʌ": [["ɐ"], ["ə"]],
    "ɪ": [["i"], ["ə"]], "i": [["ɪ"], ["ə"]], "ʊ": [["u"], ["ə"]], "u": [["ʊ"], ["ə"]],
    "ɒ": [["ə"]], "e": [["ə"], ["ɛ"]],
    "dʒ": [["t", "ʃ"], ["t͡ʃ"]], "ɹ": [["ə˞"], ["ɜ˞"]],
  ]

  static let PAIRS: [PhonePair: [[String]]] = [
    PhonePair("ə", "ɹ"): [["ɜ˞"], ["ə˞"], ["ɛ", "ɹ"], ["ɹ"]],
    PhonePair("ɜː", "ɹ"): [["ɜ˞"], ["ə˞"]],
  ]

  // Real, acoustically confusable substitutions for RP L2 learners. `likelyIncorrect`
  // fires ONLY when the model's preferred competitor is in the expected phone's set.
  // Symmetric pairs below are expanded into both directions, mirroring Python's
  // `CONFUSION.setdefault(a,set()).add(b); CONFUSION.setdefault(b,set()).add(a)`.
  static let CONFUSION: [String: Set<String>] = {
    let pairs: [(String, String)] = [
      ("θ", "s"), ("θ", "f"), ("θ", "t"), ("ð", "d"), ("ð", "z"), ("ð", "v"),
      ("v", "w"), ("v", "f"), ("b", "v"), ("p", "f"), ("w", "ɹ"),
      ("l", "ɹ"), ("ʃ", "s"), ("ʒ", "z"), ("ʒ", "dʒ"), ("tʃ", "ʃ"), ("tʃ", "t"), ("dʒ", "ʒ"), ("dʒ", "j"),
      ("ŋ", "n"), ("ɪ", "iː"), ("æ", "e"), ("æ", "ʌ"), ("ʌ", "ɑː"), ("ʊ", "uː"), ("ɒ", "ɔː"), ("ɒ", "əʊ"), ("e", "ɜː"),
      ("z", "s"), ("d", "t"), ("b", "p"), ("ɡ", "k"),
    ]
    var table: [String: Set<String>] = [:]
    for (a, b) in pairs {
      table[a, default: []].insert(b)
      table[b, default: []].insert(a)
    }
    return table
  }()

  /// Special/unmapped vocab ids 0-3 (blank + reserved) are never a valid phone encoding.
  private static let reservedIDCeiling = 4

  /// Order-preserving de-duplication of token-id sequences — mirrors Python's
  /// `dict.fromkeys(tuple(s) for s in seqs)`.
  private static func dedupe(_ sequences: [[Int]]) -> [[Int]] {
    var seen = Set<[Int]>()
    var result: [[Int]] = []
    for sequence in sequences where seen.insert(sequence).inserted { result.append(sequence) }
    return result
  }

  /// Cartesian product of per-position choices, e.g. `[["a","a~"],["b"]]` -> `[["a","b"],["a~","b"]]`.
  private static func cartesianProduct(_ options: [[String]]) -> [[String]] {
    options.reduce([[]]) { partial, choice in partial.flatMap { prefix in choice.map { prefix + [$0] } } }
  }

  /// Port of `_nasal`: for each symbol in `sequence`, optionally add its nasalized variant
  /// (combining tilde U+0303) when the vocab has that token, then take the cartesian product.
  private static func nasalVariants(_ sequence: [String], _ vocab: [String: Int]) -> [[String]] {
    let options: [[String]] = sequence.map { symbol in
      let nasalized = symbol + "\u{0303}"
      return vocab[nasalized] != nil ? [symbol, nasalized] : [symbol]
    }
    return cartesianProduct(options)
  }

  /// Port of `_expand`: nasalized variants of each candidate sequence, token-encoded, keeping
  /// only variants whose every symbol is present in `vocab`.
  private static func expand(_ sequences: [[String]], _ vocab: [String: Int]) -> [[Int]] {
    var result: [[Int]] = []
    for sequence in sequences {
      for variant in nasalVariants(sequence, vocab) where variant.allSatisfy({ vocab[$0] != nil }) {
        result.append(variant.map { vocab[$0]! })
      }
    }
    return result
  }

  /// Port of `encode`: spelling/alias-normalized token-id sequence for one phone, or `nil` if the
  /// vocab does not have it (or maps it to a special/reserved id < 4).
  static func encode(_ phone: String, _ vocab: [String: Int]) -> [Int]? {
    let alias = ["r": "ɹ", "g": "ɡ", "e": "ɛ", "tʃ": "t͡ʃ", "dʒ": "d͡ʒ"][phone] ?? phone
    let symbols = DIPHTHONGS[phone] ?? [alias]
    if symbols.contains(where: { (vocab[$0] ?? -1) < reservedIDCeiling }) { return nil }
    return symbols.map { vocab[$0]! }
  }

  /// Port of `accepted`. Phonetic realizations of one UK phoneme: allophones plus label-convention
  /// classes A/B/C.
  ///
  /// Never a LOT/PALM, BATH/TRAP, rhoticity or quality merge. `wordInitial` applies the aspiration
  /// rule: initial /p t k/ accept only [pʰ tʰ kʰ], so /b d g/→[p t k] stays separable.
  static func accepted(_ phone: String, _ vocab: [String: Int], wordInitial: Bool = false) -> [[Int]] {
    guard let base = encode(phone, vocab) else { return [] }
    if wordInitial, let aspiratedSymbol = ASPIRATED[phone], let id = vocab[aspiratedSymbol] { return [[id]] }
    var result: [[Int]] = [base]
    let symbol = ["r": "ɹ", "g": "ɡ", "e": "ɛ"][phone] ?? phone
    var alternatives: [String] = [
      "p": ["pʰ"], "t": ["tʰ"], "k": ["kʰ"], "l": ["l̴", "lˠ"],
      "tʃ": ["t͡ʃʰ"], "e": ["e"], "ɛ": ["e"],
    ][phone] ?? []
    if ukVowelPrefix.contains(phone) { alternatives.append(symbol + "\u{0303}") }
    for alt in alternatives where vocab[alt] != nil { result.append([vocab[alt]!]) }
    let splitSequences: [[String]]
    switch phone {
    case "tʃ": splitSequences = [["t", "ʃ"], ["tʰ", "ʃ"]]
    case "dʒ": splitSequences = [["d", "ʒ"]]
    default: splitSequences = []
    }
    for sequence in splitSequences where sequence.allSatisfy({ vocab[$0] != nil }) {
      result.append(sequence.map { vocab[$0]! })
    }
    if let parts = DIPHTHONGS[phone] {
      for variant in nasalVariants(parts, vocab) { result.append(variant.map { vocab[$0]! }) }
    }
    if let lengthless = LENGTHLESS[phone] { result += expand([[lengthless]], vocab) }
    result += expand(GOAT[phone] ?? [], vocab)
    if let devoiced = DEVOICED[phone], let id = vocab[devoiced] { result.append([id]) }
    return dedupe(result)
  }

  /// Port of `conditional`: Class D realizations for Stage A licensing; excludes anything already
  /// `accepted`.
  static func conditional(_ phone: String, _ vocab: [String: Int]) -> [[Int]] {
    let allowed = Set(accepted(phone, vocab))
    return dedupe(expand(CONDITIONAL[phone] ?? [], vocab)).filter { !allowed.contains($0) }
  }

  /// Port of `pair_realizations`.
  static func pairRealizations(_ p: String, _ q: String, _ vocab: [String: Int]) -> [[Int]] {
    dedupe(expand(PAIRS[PhonePair(p, q)] ?? [], vocab))
  }

  /// One scoring unit: 1-2 display phones of one word, their accepted and class-D token sequences.
  struct Unit: Equatable {
    let word: String
    let indices: [Int]
    let display: [String]
    let allowed: [[Int]]
    let cond: [[Int]]
    let wordInitial: Bool
    var id: String { "\(word):\(indices[0])" }
  }

  /// Port of `build_units`. `words`: `(word_id, [phones])` of the selected variants. Adjacent
  /// `PAIRS` become one unit.
  static func buildUnits(_ words: [(String, [String])], _ vocab: [String: Int]) throws -> [Unit] {
    var units: [Unit] = []
    for (wid, phones) in words {
      var i = 0
      while i < phones.count {
        let p = phones[i]
        if i + 1 < phones.count, PAIRS[PhonePair(p, phones[i + 1])] != nil {
          let q = phones[i + 1]
          let ga = accepted(p, vocab, wordInitial: i == 0)
          let gb = accepted(q, vocab)
          guard !ga.isEmpty, !gb.isEmpty else {
            throw XeusInventoryError.unsupportedTargetPhone("\(p) \(q)")
          }
          let allowed = dedupe(ga.flatMap { a in gb.map { b in a + b } })
          let allowedSet = Set(allowed)
          let condP = conditional(p, vocab)
          let condQ = conditional(q, vocab)
          let combos = (ga + condP).flatMap { a in (gb + condQ).map { b in a + b } }
          let cond = dedupe(pairRealizations(p, q, vocab) + combos).filter { !allowedSet.contains($0) }
          units.append(Unit(word: wid, indices: [i, i + 1], display: [p, q], allowed: allowed, cond: cond, wordInitial: i == 0))
          i += 2
        } else {
          let allowed = accepted(p, vocab, wordInitial: i == 0)
          guard !allowed.isEmpty else { throw XeusInventoryError.unsupportedTargetPhone(p) }
          let allowedSet = Set(allowed)
          let cond = conditional(p, vocab).filter { !allowedSet.contains($0) }
          units.append(Unit(word: wid, indices: [i], display: [p], allowed: allowed, cond: cond, wordInitial: i == 0))
          i += 1
        }
      }
    }
    return units
  }
}

/// Port of the `ValueError('unsupported target phone: ' + ...)` raised by `accepted`-consuming
/// call sites in `evidence.py` (`build_units`, `assess_phones`).
enum XeusInventoryError: Error, LocalizedError, Equatable {
  case unsupportedTargetPhone(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedTargetPhone(let phone): return "unsupported target phone: \(phone)"
    }
  }
}
