import Foundation
import Testing
@testable import ToSpeech

/// Parity tests ported from `scripts/assessment/phoneticxeus/test_evidence.py`, using the same
/// tiny synthetic vocabs (built the same way as the Python `vocab428` helper: 428 placeholder
/// entries `x0...x427`, overridden with the named phones each test cares about).
@Suite struct XeusInventoryTests {
  /// Mirrors Python's `self.vocab428(**names)`: `{f'x{i}':i for i in range(428)}` plus `<blank>:0`,
  /// overridden with the given phone->id entries.
  private func vocab428(_ overrides: [String: Int]) -> [String: Int] {
    var vocab = Dictionary(uniqueKeysWithValues: (0..<428).map { ("x\($0)", $0) })
    vocab["<blank>"] = 0
    for (symbol, id) in overrides { vocab[symbol] = id }
    return vocab
  }

  // MARK: test_uk_mapping_preserves_contrasts

  @Test func mappingPreservesContrasts() {
    let vocab: [String: Int] = [
      "<blank>": 0, "ɒ": 4, "ɑː": 5, "ɪ": 6, "iː": 7, "ə": 8, "ʊ": 9, "t͡ʃ": 10, "ɹ": 11,
    ]
    #expect(XeusInventory.encode("ɒ", vocab) != XeusInventory.encode("ɑː", vocab))
    #expect(XeusInventory.encode("ɪ", vocab) != XeusInventory.encode("iː", vocab))
    #expect(XeusInventory.encode("əʊ", vocab) == [8, 9])
    #expect(XeusInventory.encode("tʃ", vocab) == [10])
    #expect(XeusInventory.encode("missing", vocab) == nil)
  }

  // MARK: test_class_a_length_never_emitted_is_accepted_without_merging_quality

  @Test func classALengthNeverEmittedIsAcceptedWithoutMergingQuality() {
    #expect(XeusInventory.mapping == "xeus-uk-inventory-v4")
    let v = vocab428([
      "iː": 4, "i": 5, "ɪ": 6, "uː": 7, "u": 8, "ʊ": 9, "ɑː": 10, "ɑ": 11, "ɒ": 12, "ʌ": 13, "ɔː": 14, "ɔ": 15,
    ])
    #expect(XeusInventory.accepted("iː", v).contains([5]))
    #expect(!XeusInventory.accepted("iː", v).contains([6]))
    #expect(XeusInventory.accepted("uː", v).contains([8]))
    #expect(!XeusInventory.accepted("uː", v).contains([9]))
    #expect(XeusInventory.accepted("ɑː", v).contains([11]))
    #expect(!XeusInventory.accepted("ɑː", v).contains([12]))
    #expect(!XeusInventory.accepted("ɑː", v).contains([13]))
    #expect(XeusInventory.accepted("ɔː", v).contains([15]))
    #expect(!XeusInventory.accepted("ɔː", v).contains([12]))
  }

  // MARK: test_class_b_goat_accepts_o_glide_sequence_but_never_o_alone

  @Test func classBGoatAcceptsOGlideSequenceButNeverOAlone() {
    let v = vocab428(["ə": 4, "ʊ": 5, "o": 6, "ʊ̃": 7])
    #expect(XeusInventory.accepted("əʊ", v).contains([6, 5]))
    #expect(XeusInventory.accepted("əʊ", v).contains([6, 7]))
    #expect(!XeusInventory.accepted("əʊ", v).contains([6]))
  }

  // MARK: test_class_c_initial_devoicing_and_aspiration_rule_keep_stops_apart

  @Test func classCInitialDevoicingAndAspirationRuleKeepStopsApart() {
    let v = vocab428(["b": 4, "p": 5, "pʰ": 6, "d": 7, "t": 8, "tʰ": 9, "ɡ": 10, "k": 11, "kʰ": 12])
    #expect(XeusInventory.accepted("p", v, wordInitial: true) == [[6]])
    #expect(XeusInventory.accepted("b", v).contains([5]))
    #expect(!XeusInventory.accepted("b", v).contains([6]))
    #expect(XeusInventory.accepted("g", v).contains([11]))
    #expect(!XeusInventory.accepted("g", v).contains([12]))
    #expect(XeusInventory.accepted("t", v, wordInitial: true) == [[9]])
    #expect(XeusInventory.accepted("t", v).contains([8]))
    for (unvoiced, voiceless) in [("b", "p"), ("d", "t"), ("g", "k")] {
      let unvoicedSet = Set(XeusInventory.accepted(unvoiced, v))
      let initialVoicelessSet = Set(XeusInventory.accepted(voiceless, v, wordInitial: true))
      #expect(unvoicedSet.isDisjoint(with: initialVoicelessSet))
    }
  }

  // MARK: test_conditional_classes_are_not_globally_accepted

  @Test func conditionalClassesAreNotGloballyAccepted() {
    let v = vocab428(["ɛ": 4, "ə": 5, "ɹ": 6, "ɜ˞": 7, "ɑː": 8, "ɑ": 9, "ɪ": 10, "i": 11])
    #expect(!XeusInventory.accepted("ɑː", v).contains([9, 6]))
    #expect(XeusInventory.conditional("ɑː", v).contains([9, 6]))
    #expect(!XeusInventory.accepted("ɛə", v).contains([4, 6]))
    #expect(XeusInventory.conditional("ɛə", v).contains([4, 6]))
    #expect(XeusInventory.conditional("ɪ", v).contains([11]))
    #expect(!XeusInventory.accepted("ɪ", v).contains([11]))
    #expect(XeusInventory.pairRealizations("ə", "ɹ", v).contains([7]))
  }

  // MARK: test_build_units_merges_schwa_r_pair_and_marks_word_initial

  @Test func buildUnitsMergesSchwaRPairAndMarksWordInitial() throws {
    let v = vocab428([
      "l": 4, "ɪ": 5, "t": 6, "tʰ": 7, "ə": 8, "ɹ": 9, "ɜ˞": 10, "ʃ": 11, "t͡ʃ": 12, "ɛ": 13,
    ])
    let units = try XeusInventory.buildUnits([("w1", ["l", "ɪ", "t", "ə", "ɹ", "ə", "tʃ", "ə"])], v)
    #expect(units.map(\.display) == [["l"], ["ɪ"], ["t"], ["ə", "ɹ"], ["ə"], ["tʃ"], ["ə"]])
    #expect(units[3].indices == [3, 4])
    #expect(units[3].cond.contains([10]))
    #expect(!units[3].allowed.contains([10]))
    #expect(units[0].wordInitial)
    #expect(!units[2].wordInitial)
    #expect(units[3].id == "w1:3")
  }

  @Test func buildUnitsRejectsAnUnsupportedTargetPhone() {
    let v = vocab428([:])
    #expect(throws: XeusInventoryError.self) {
      _ = try XeusInventory.buildUnits([("w", ["ʑ"])], v)
    }
  }

  // MARK: test_contrast_token_sets_stay_disjoint

  @Test func contrastTokenSetsStayDisjoint() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let vocabURL = repoRoot.appendingPathComponent(
      "vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/ipa_vocab.json")
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
    let pairs: [(String, String)] = [
      ("θ", "s"), ("ð", "d"), ("v", "w"), ("f", "v"), ("ɪ", "iː"), ("ɪ", "i"), ("æ", "ɛ"),
      ("ʊ", "uː"), ("ɒ", "ɔː"), ("ʌ", "ɑː"), ("ɒ", "ɑː"), ("ɜː", "ə"), ("ʃ", "s"), ("ʒ", "ʃ"),
      ("tʃ", "ʃ"), ("dʒ", "tʃ"), ("n", "ŋ"), ("l", "ɹ"), ("əʊ", "ɔː"), ("əʊ", "ʊ"), ("eɪ", "ɛ"),
      ("aɪ", "ɑː"),
    ]
    for (a, b) in pairs {
      let setA = Set(XeusInventory.accepted(a, vocab))
      let setB = Set(XeusInventory.accepted(b, vocab))
      #expect(setA.isDisjoint(with: setB), "\(a) vs \(b) must stay disjoint")
    }
  }

  // MARK: exact-code-point vocab lookups (parity with Python's byte-equality `dict[str,int]`)

  /// `ipa_vocab.json` can store a nasal vowel key either precomposed (single code point, e.g.
  /// 'ẽ' U+1EBD) or decomposed (base + combining tilde U+0303) — `evidence.py`'s `_nasal` always
  /// builds the DECOMPOSED lookup key (`s + '̃'`). Python's plain `str` dict equality treats
  /// a precomposed 'ẽ' as a DIFFERENT key from the decomposed 'e'+'̃' it looks up, so it
  /// never matches; Swift's `String`/`Dictionary` equality is canonical-equivalence-aware (NFC
  /// 'ẽ' == NFD 'e'+combining-tilde), so an un-fixed port would wrongly match it. This is the
  /// exact vocab shape used by the real `missing_glide_cannot_borrow_from_first_vowel` golden
  /// fixture (`XeusAssessTests`) — reproduced here directly against `accepted`.
  @Test func acceptedTreatsPrecomposedAndDecomposedNasalVowelsAsDistinctKeysLikePython() {
    let v = vocab428(["e": 4, "ɪ": 5, "\u{1EBD}": 6, "ɪ\u{0303}": 7])  // 'ẽ' precomposed, 'ɪ̃' decomposed
    let result = XeusInventory.accepted("eɪ", v)
    // Python ground truth (`evidence.accepted('eɪ', vocab)` with this exact vocab): 2 realizations,
    // not 4 — 'e' has no DECOMPOSED nasal counterpart in this vocab (only the unrelated precomposed
    // 'ẽ'), so only 'ɪ' gets a nasal alternative.
    #expect(result.count == 2, "expected Python's byte-exact count of 2, got \(result)")
    #expect(Set(result) == Set([[4, 5], [4, 7]]))
    // The canonical-equivalence bug this guards against: matching the precomposed 'ẽ' (id 6)
    // against the decomposed lookup key "e"+"\u{0303}" would wrongly add these two realizations.
    #expect(!result.contains([6, 5]))
    #expect(!result.contains([6, 7]))
  }

  // MARK: broad real-vocab parity check (Python ground truth via `evidence.py`)

  /// Ground truth from the real Python pipeline: `evidence.accepted(phone, vocab)` for every
  /// `UK[:27]` + `DIPHTHONGS` phone (the full nasal-capable vowel/diphthong set), run against the
  /// REAL `ipa_vocab.json` shipped with the app (not a synthetic vocab). Computed 2026-09-16 with
  /// `/tmp/echolab-xeus-env/bin/python3` running the actual `scripts/assessment/phoneticxeus/
  /// evidence.py` against `vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/
  /// ipa_vocab.json`. The real vocab happens to store every nasal vowel already DECOMPOSED (base
  /// + U+0303), so this particular set does not itself exercise the precomposed-key bug (see
  /// `acceptedTreatsPrecomposedAndDecomposedNasalVowelsAsDistinctKeysLikePython` above for that
  /// scenario) — it is the broader load-bearing parity guarantee that `accepted` returns exactly
  /// the same token-id sets as Python for the real, shipped vocab.
  private static let pythonAcceptedGoldenForRealVocab: [String: [[Int]]] = [
    "iː": [[341], [189], [22]],
    "ɪ": [[360], [250]],
    "e": [[51], [181], [29]],
    "ɛ": [[51], [181], [29]],
    "æ": [[162], [412]],
    "ɑː": [[175], [123], [184]],
    "ɒ": [[40]],
    "ɔː": [[210], [191], [119]],
    "ʊ": [[292], [75]],
    "uː": [[204], [183], [215]],
    "ʌ": [[53], [326]],
    "ɐ": [[117], [262]],
    "ɜː": [[57], [139]],
    "ə": [[24], [245]],
    "i": [[189], [22]],
    "u": [[183], [215]],
    "eɪ": [[181, 360], [181, 250], [38, 360], [38, 250]],
    "aɪ": [[227, 360], [227, 250], [114, 360], [114, 250]],
    "ɔɪ": [[191, 360], [191, 250], [119, 360], [119, 250]],
    "əʊ": [[24, 292], [24, 75], [245, 292], [245, 75], [185, 292], [185, 75], [179, 292], [179, 75]],
    "aʊ": [[227, 292], [227, 75], [114, 292], [114, 75]],
    "ɪə": [[360, 24], [360, 245], [250, 24], [250, 245]],
    "eə": [[51, 24], [51, 245], [29, 24], [29, 245]],
    "ʊə": [[292, 24], [292, 245], [75, 24], [75, 245]],
    "ɛː": [[374], [51], [29]],
    "ɪː": [[327], [360], [250]],
    "ʊː": [[252], [292], [75]],
    "ɛə": [[51, 24], [51, 245], [29, 24], [29, 245]],
  ]

  @Test func acceptedMatchesPythonGoldenForEveryNasalCapablePhoneOnTheRealVocab() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let vocabURL = repoRoot.appendingPathComponent(
      "vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/ipa_vocab.json")
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
    for (phone, expected) in Self.pythonAcceptedGoldenForRealVocab {
      let actual = XeusInventory.accepted(phone, vocab)
      #expect(actual.count == expected.count, "\(phone): dedupe count mismatch, got \(actual)")
      #expect(Set(actual) == Set(expected), "\(phone): got \(actual), expected \(expected)")
    }
  }

  // MARK: test_confusion_gate_flags_only_confusable_substitutions (CONFUSION-table membership)

  @Test func confusionTableMembershipIsSymmetricAndScoped() {
    #expect(XeusInventory.CONFUSION["v"]?.contains("w") == true)
    #expect(XeusInventory.CONFUSION["w"]?.contains("v") == true)
    #expect(XeusInventory.CONFUSION["b"]?.contains("v") == true)
    #expect(XeusInventory.CONFUSION["b"]?.contains("p") == true)
    // θ is confusable with s/f/t, but never with an unrelated phone like z.
    #expect(XeusInventory.CONFUSION["θ"]?.contains("z") != true)
  }
}
