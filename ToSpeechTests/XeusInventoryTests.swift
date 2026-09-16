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
