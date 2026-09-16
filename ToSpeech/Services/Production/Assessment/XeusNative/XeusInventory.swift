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

  /// Code-point-exact (non-canonicalizing) key wrapper for vocab lookups.
  ///
  /// Python's `dict[str, int]` compares/hashes `str` by its exact Unicode code point sequence.
  /// Swift's native `String` (and therefore `[String: Int]`'s `==`/`Hashable`) is
  /// canonical-equivalence-aware: a precomposed key such as `"ẽ"` (U+1EBD) and a decomposed
  /// sequence `"e" + "\u{0303}"` (combining tilde) compare EQUAL and hash identically in Swift,
  /// even though they are two different entries — or a present vs. absent one — in the Python
  /// vocab dict. `ipa_vocab.json` is exactly this: some entries are stored precomposed, some
  /// decomposed (see `nasalVariants`, which builds decomposed lookup keys). Comparing/hashing the
  /// raw `unicodeScalars` values instead reproduces Python's exact code-point equality, so a
  /// precomposed vocab key and a decomposed lookup are treated as DISTINCT, never matched — the
  /// same as Python, and never NFC/NFD-normalized to make them match.
  private struct ExactKey: Hashable {
    let scalars: [UInt32]
    init(_ string: String) { scalars = string.unicodeScalars.map(\.value) }
  }

  /// Rebuilds `vocab` into a code-point-exact lookup table once per public entry point; every
  /// nested/private helper below takes this table (not the raw `[String: Int]`) so a single call
  /// tree does exactly one exact-equality-safe conversion, not one per lookup.
  private static func exactVocab(_ vocab: [String: Int]) -> [ExactKey: Int] {
    var result: [ExactKey: Int] = [:]
    result.reserveCapacity(vocab.count)
    for (key, value) in vocab { result[ExactKey(key)] = value }
    return result
  }

  /// Code-point-exact membership/lookup against an already-converted vocab table.
  private static func exactID(_ symbol: String, _ vocab: [ExactKey: Int]) -> Int? {
    vocab[ExactKey(symbol)]
  }

  /// Port of `_nasal`: for each symbol in `sequence`, optionally add its nasalized variant
  /// (combining tilde U+0303) when the vocab has that EXACT token, then take the cartesian product.
  private static func nasalVariants(_ sequence: [String], _ vocab: [ExactKey: Int]) -> [[String]] {
    let options: [[String]] = sequence.map { symbol in
      let nasalized = symbol + "\u{0303}"
      return exactID(nasalized, vocab) != nil ? [symbol, nasalized] : [symbol]
    }
    return cartesianProduct(options)
  }

  /// Port of `_expand`: nasalized variants of each candidate sequence, token-encoded, keeping
  /// only variants whose every symbol is present (code-point-exact) in `vocab`.
  private static func expand(_ sequences: [[String]], _ vocab: [ExactKey: Int]) -> [[Int]] {
    var result: [[Int]] = []
    for sequence in sequences {
      for variant in nasalVariants(sequence, vocab) where variant.allSatisfy({ exactID($0, vocab) != nil }) {
        result.append(variant.map { exactID($0, vocab)! })
      }
    }
    return result
  }

  /// Port of `encode`: spelling/alias-normalized token-id sequence for one phone, or `nil` if the
  /// vocab does not have it (code-point-exact) or maps it to a special/reserved id < 4.
  private static func encodeExact(_ phone: String, _ vocab: [ExactKey: Int]) -> [Int]? {
    let alias = ["r": "ɹ", "g": "ɡ", "e": "ɛ", "tʃ": "t͡ʃ", "dʒ": "d͡ʒ"][phone] ?? phone
    let symbols = DIPHTHONGS[phone] ?? [alias]
    if symbols.contains(where: { (exactID($0, vocab) ?? -1) < reservedIDCeiling }) { return nil }
    return symbols.map { exactID($0, vocab)! }
  }

  /// Port of `encode`: spelling/alias-normalized token-id sequence for one phone, or `nil` if the
  /// vocab does not have it (or maps it to a special/reserved id < 4).
  static func encode(_ phone: String, _ vocab: [String: Int]) -> [Int]? {
    encodeExact(phone, exactVocab(vocab))
  }

  /// Port of `accepted`, against an already-converted (code-point-exact) vocab table.
  private static func acceptedExact(_ phone: String, _ vocab: [ExactKey: Int], wordInitial: Bool) -> [[Int]] {
    guard let base = encodeExact(phone, vocab) else { return [] }
    if wordInitial, let aspiratedSymbol = ASPIRATED[phone], let id = exactID(aspiratedSymbol, vocab) {
      return [[id]]
    }
    var result: [[Int]] = [base]
    let symbol = ["r": "ɹ", "g": "ɡ", "e": "ɛ"][phone] ?? phone
    var alternatives: [String] = [
      "p": ["pʰ"], "t": ["tʰ"], "k": ["kʰ"], "l": ["l̴", "lˠ"],
      "tʃ": ["t͡ʃʰ"], "e": ["e"], "ɛ": ["e"],
    ][phone] ?? []
    if ukVowelPrefix.contains(phone) { alternatives.append(symbol + "\u{0303}") }
    for alt in alternatives { if let id = exactID(alt, vocab) { result.append([id]) } }
    let splitSequences: [[String]]
    switch phone {
    case "tʃ": splitSequences = [["t", "ʃ"], ["tʰ", "ʃ"]]
    case "dʒ": splitSequences = [["d", "ʒ"]]
    default: splitSequences = []
    }
    for sequence in splitSequences where sequence.allSatisfy({ exactID($0, vocab) != nil }) {
      result.append(sequence.map { exactID($0, vocab)! })
    }
    if let parts = DIPHTHONGS[phone] {
      for variant in nasalVariants(parts, vocab) { result.append(variant.map { exactID($0, vocab)! }) }
    }
    if let lengthless = LENGTHLESS[phone] { result += expand([[lengthless]], vocab) }
    result += expand(GOAT[phone] ?? [], vocab)
    if let devoiced = DEVOICED[phone], let id = exactID(devoiced, vocab) { result.append([id]) }
    return dedupe(result)
  }

  /// Port of `accepted`. Phonetic realizations of one UK phoneme: allophones plus label-convention
  /// classes A/B/C.
  ///
  /// Never a LOT/PALM, BATH/TRAP, rhoticity or quality merge. `wordInitial` applies the aspiration
  /// rule: initial /p t k/ accept only [pʰ tʰ kʰ], so /b d g/→[p t k] stays separable.
  static func accepted(_ phone: String, _ vocab: [String: Int], wordInitial: Bool = false) -> [[Int]] {
    acceptedExact(phone, exactVocab(vocab), wordInitial: wordInitial)
  }

  /// Port of `conditional`, against an already-converted (code-point-exact) vocab table.
  private static func conditionalExact(_ phone: String, _ vocab: [ExactKey: Int]) -> [[Int]] {
    let allowed = Set(acceptedExact(phone, vocab, wordInitial: false))
    return dedupe(expand(CONDITIONAL[phone] ?? [], vocab)).filter { !allowed.contains($0) }
  }

  /// Port of `conditional`: Class D realizations for Stage A licensing; excludes anything already
  /// `accepted`.
  static func conditional(_ phone: String, _ vocab: [String: Int]) -> [[Int]] {
    conditionalExact(phone, exactVocab(vocab))
  }

  /// Port of `pair_realizations`, against an already-converted (code-point-exact) vocab table.
  private static func pairRealizationsExact(_ p: String, _ q: String, _ vocab: [ExactKey: Int]) -> [[Int]] {
    dedupe(expand(PAIRS[PhonePair(p, q)] ?? [], vocab))
  }

  /// Port of `pair_realizations`.
  static func pairRealizations(_ p: String, _ q: String, _ vocab: [String: Int]) -> [[Int]] {
    pairRealizationsExact(p, q, exactVocab(vocab))
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
    let exact = exactVocab(vocab)
    var units: [Unit] = []
    for (wid, phones) in words {
      var i = 0
      while i < phones.count {
        let p = phones[i]
        if i + 1 < phones.count, PAIRS[PhonePair(p, phones[i + 1])] != nil {
          let q = phones[i + 1]
          let ga = acceptedExact(p, exact, wordInitial: i == 0)
          let gb = acceptedExact(q, exact, wordInitial: false)
          guard !ga.isEmpty, !gb.isEmpty else {
            throw XeusInventoryError.unsupportedTargetPhone("\(p) \(q)")
          }
          let allowed = dedupe(ga.flatMap { a in gb.map { b in a + b } })
          let allowedSet = Set(allowed)
          let condP = conditionalExact(p, exact)
          let condQ = conditionalExact(q, exact)
          let combos = (ga + condP).flatMap { a in (gb + condQ).map { b in a + b } }
          let cond = dedupe(pairRealizationsExact(p, q, exact) + combos).filter { !allowedSet.contains($0) }
          units.append(Unit(word: wid, indices: [i, i + 1], display: [p, q], allowed: allowed, cond: cond, wordInitial: i == 0))
          i += 2
        } else {
          let allowed = acceptedExact(p, exact, wordInitial: i == 0)
          guard !allowed.isEmpty else { throw XeusInventoryError.unsupportedTargetPhone(p) }
          let allowedSet = Set(allowed)
          let cond = conditionalExact(p, exact).filter { !allowedSet.contains($0) }
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
