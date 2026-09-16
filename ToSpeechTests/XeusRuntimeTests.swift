import Foundation
import Testing
@testable import ToSpeech

/// Parity tests ported from `scripts/assessment/phoneticxeus/test_runtime.py` — `stage_a` licensing
/// (`test_class_d_realization_is_licensed_only_from_reference`,
/// `test_unmapped_and_weak_reference_states`,
/// `test_accepted_licence_with_a_non_correct_source_is_demoted_to_weak`,
/// `test_weak_reference_blocks_take_with_reason`), `apply_head_take` head bands
/// (`test_head_bands_on_take_and_missing_head`) and the class-D skip
/// (`test_apply_head_take_never_flips_a_classd_licensed_unit`), the per-word native mask
/// (`test_word_mask_grays_whole_word_when_native_unit_not_confident`,
/// `test_word_mask_overwrites_a_would_be_green_row_but_preserves_sibling_reason`),
/// `test_cannot_distinguish_always_overrides_a_correct_take`, and the OkayFixtureTests unmapped-list
/// case — plus the load-bearing clip-level parity: run `assembleFromLogits` on the real Task 2
/// `{okay,vest-uk,full-source}.logits.npy` and assert per-phone status+reason and coverage match the
/// golden `*.decisions.json` EXACTLY (excluding the machine-dependent fields per manifest.json).
@Suite struct XeusRuntimeTests {
  // MARK: - lp / vocab construction (byte-for-byte port of test_runtime.py's `self.lp`/`self.vocab`)

  private func lp(_ rows: [[Int: Double]], vocabSize: Int = 428, floor: Double = 1e-8) -> [[Double]] {
    rows.map { values in
      var row = [Double](repeating: floor, count: vocabSize)
      for (token, prob) in values { row[token] = prob }
      let sum = row.reduce(0, +)
      return row.map { Foundation.log($0 / sum) }
    }
  }

  /// Port of test_runtime.py's `StageATests.vocab(**names)`: `{f'x{i}':i}` + `<blank>` + overrides.
  private func vocab(_ overrides: [String: Int] = [:]) -> [String: Int] {
    var v: [String: Int] = [:]
    for i in 0..<428 { v["x\(i)"] = i }
    v["<blank>"] = 0
    for (symbol, id) in overrides { v[symbol] = id }
    return v
  }

  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }

  private func syntheticHead() throws -> XeusContrastHead {
    let url = repoRoot.appendingPathComponent("ToSpeechTests/Fixtures/XeusNative/contrast-head-synthetic.json")
    return try #require(XeusContrastHead.load(url))
  }

  // MARK: - stage_a licensing

  /// Port of `test_class_d_realization_is_licensed_only_from_reference`.
  @Test func classDRealizationIsLicensedOnlyFromReference() throws {
    let v = vocab(["w": 4, "ɛ": 5, "ə": 6, "ɹ": 7])
    let units = try XeusInventory.buildUnits([("w", ["w", "ɛə"])], v)
    let src = lp([[4: 0.99], [0: 0.99], [5: 0.99], [7: 0.99], [0: 0.99]])
    let a = try XeusRuntime.stageA(src, units, v, duration: 0.10, head: nil, hidden: nil, thresholds: .standard)
    #expect(a.licences == ["accepted", "classD"])
    #expect(a.realizations[1] == [5, 7])
    #expect(a.rows[1].status == "correct")
  }

  /// Port of `test_unmapped_and_weak_reference_states`.
  @Test func unmappedReferenceState() throws {
    let v = vocab(["w": 4, "ɛ": 5, "ə": 6, "ɹ": 7, "s": 8])
    let units = try XeusInventory.buildUnits([("w", ["w", "ɛə"])], v)
    let a = try XeusRuntime.stageA(lp([[4: 0.99], [0: 0.99], [8: 0.99], [8: 0.99], [0: 0.99]]),
      units, v, duration: 0.10, head: nil, hidden: nil, thresholds: .standard)
    #expect(a.licences[1] == "unmapped")
  }

  /// Port of `test_accepted_licence_with_a_non_correct_source_is_demoted_to_weak`.
  @Test func acceptedLicenceWithNonCorrectSourceIsDemotedToWeak() throws {
    let v = vocab(["θ": 4, "s": 5])
    let units = try XeusInventory.buildUnits([("w", ["θ"])], v)
    let src = lp([[0: 0.99], [4: 0.5, 5: 0.3], [4: 0.5, 5: 0.3], [0: 0.99]])
    let take = lp([[0: 0.99], [4: 0.99], [4: 0.99], [0: 0.99]])
    let a = try XeusRuntime.stageA(src, units, v, duration: 0.08, head: nil, hidden: nil, thresholds: .standard)
    #expect(a.rows[0].status == "uncertain")
    #expect((a.rows[0].logMargin ?? 0) > 0)
    #expect(a.rows[0].start != nil)
    #expect(a.realizations == [[4]])  // accepted-shaped realization, not class D
    #expect(a.licences == ["weak"])

    let request = XeusRequest(words: [.init(id: "w", text: "th", variants: [["θ"]])])
    let evidence = try XeusRuntime.assembleFromLogits(source: src, take: take, hiddenSource: nil,
      hiddenTake: nil, vocab: v, request: request, sourceDuration: 0.08, takeDuration: 0.08,
      thresholds: .standard, head: nil)
    let row = evidence.words[0].phones[0]
    #expect(row.takeStatus == "correct")        // the take itself is fine …
    #expect(row.status == "uncertain")          // … but the reference cannot license it
    #expect(row.reason == "referenceWeak")      // already uncertain -> keeps its specific reason
    #expect(row.licence == "weak")
  }

  /// Port of `test_weak_reference_blocks_take_with_reason`.
  @Test func weakReferenceBlocksTakeWithReason() throws {
    let v = vocab(["θ": 4, "s": 5])
    let units = try XeusInventory.buildUnits([("w", ["θ"])], v)
    let src = lp([[0: 0.999], [0: 0.997, 4: 0.002], [0: 0.997, 4: 0.002], [0: 0.999]])
    let a = try XeusRuntime.stageA(src, units, v, duration: 0.08, head: nil, hidden: nil, thresholds: .standard)
    #expect(a.licences == ["weak"])

    let request = XeusRequest(words: [.init(id: "w", text: "th", variants: [["θ"]])])
    let evidence = try XeusRuntime.assembleFromLogits(source: src, take: src, hiddenSource: nil,
      hiddenTake: nil, vocab: v, request: request, sourceDuration: 0.08, takeDuration: 0.08,
      thresholds: .standard, head: nil)
    let rows = evidence.words.flatMap { $0.phones }
    #expect(rows.count == 1)
    #expect(rows[0].status == "uncertain")
    #expect(rows[0].reason == "referenceWeak")
    #expect(rows[0].licence == "weak")
  }

  // MARK: - apply_head_take

  /// Port of `test_head_bands_on_take_and_missing_head`.
  @Test func headBandsOnTakeAndMissingHead() throws {
    let v = vocab(["ɡ": 4, "ɹ": 5, "ɑː": 6, "ɑ": 7, "æ": 8, "s": 9])
    let units = try XeusInventory.buildUnits([("w", ["g", "ɹ", "ɑː", "s"])], v)
    let rows: [XeusRuntime.AssessRow] = [
      .init(status: "correct"), .init(status: "correct"),
      .init(status: "likelyIncorrect", windowStart: 2, windowEnd: 4, closestPhone: "æ"),
      .init(status: "correct"),
    ]
    let licences = ["accepted", "accepted", "accepted", "accepted"]
    let head = try syntheticHead()

    var hidden = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 6)
    for t in 2..<4 { hidden[t][0] = 1.0 }
    var out = XeusRuntime.applyHeadTake(units, rows, licences, head: head, hidden: hidden)
    #expect(out.rows[2].status == "correct")
    #expect(out.rows[2].reason == "contrastHead")
    #expect(out.contrasts[2]?.decision == "uk")

    for t in 2..<4 { hidden[t][0] = -1.0 }
    out = XeusRuntime.applyHeadTake(units, rows, licences, head: head, hidden: hidden)
    #expect(out.rows[2].status == "likelyIncorrect")
    #expect(out.rows[2].closestPhone == "æ")

    for t in 2..<4 { hidden[t][0] = 0.0 }
    out = XeusRuntime.applyHeadTake(units, rows, licences, head: head, hidden: hidden)
    #expect(out.rows[2].status == "uncertain")
    #expect(out.rows[2].reason == "ambiguous")

    let missing = XeusRuntime.applyHeadTake(units, rows, licences, head: nil, hidden: nil)
    #expect(missing.rows[2].status == "uncertain")
    #expect(missing.rows[2].reason == "modelCannotDistinguish")
  }

  /// Port of `test_apply_head_take_never_flips_a_classd_licensed_unit` — a class-D-licensed unit must
  /// never be flipped to red by the take-side head (the head-consultation branch is skipped entirely).
  @Test func applyHeadTakeNeverFlipsAClassDLicensedUnit() throws {
    let v = vocab(["ɡ": 4, "ɹ": 5, "ɑː": 6, "ɑ": 7, "æ": 8, "s": 9])
    let units = try XeusInventory.buildUnits([("w", ["g", "ɹ", "ɑː", "s"])], v)
    let rows: [XeusRuntime.AssessRow] = [
      .init(status: "correct"), .init(status: "correct"),
      .init(status: "uncertain", reason: "ambiguousSubstitution", windowStart: 2, windowEnd: 4, closestPhone: "æ"),
      .init(status: "correct"),
    ]
    let licences = ["accepted", "accepted", "classD", "accepted"]
    let head = try syntheticHead()
    var hidden = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 6)
    for t in 2..<4 { hidden[t][0] = -1.0 }  // would decide 'us' if consulted
    let out = XeusRuntime.applyHeadTake(units, rows, licences, head: head, hidden: hidden)
    #expect(out.rows[2].status == "uncertain")               // never red
    #expect(out.rows[2].status != "likelyIncorrect")
    #expect(out.rows[2].reason == "ambiguousSubstitution")   // untouched
    #expect(out.contrasts[2] == nil)                         // head-consultation branch skipped
  }

  // MARK: - per-word native-competence mask

  /// Port of `test_word_mask_grays_whole_word_when_native_unit_not_confident`.
  @Test func wordMaskGraysWholeWordWhenNativeUnitNotConfident() throws {
    let v = vocab(["θ": 4, "s": 5, "ʃ": 6])
    let src = lp([[0: 0.999], [0: 0.997, 4: 0.002], [0: 0.997, 4: 0.002], [0: 0.999], [5: 0.99], [0: 0.999]])
    let take = lp([[0: 0.999], [0: 0.999], [0: 0.999], [0: 0.999], [6: 0.98, 5: 0.001], [6: 0.95, 5: 0.001], [0: 0.999]])
    let request = XeusRequest(words: [.init(id: "w0", text: "test", variants: [["θ", "s"]])])
    let evidence = try XeusRuntime.assembleFromLogits(source: src, take: take, hiddenSource: nil,
      hiddenTake: nil, vocab: v, request: request, sourceDuration: Double(src.count) * 0.02,
      takeDuration: Double(take.count) * 0.02, thresholds: .standard, head: nil)
    let phones = evidence.words[0].phones
    #expect(phones.allSatisfy { $0.status != "likelyIncorrect" })
    #expect(phones.contains { $0.reason == "referenceNotConfident" })
  }

  /// Port of `test_word_mask_overwrites_a_would_be_green_row_but_preserves_sibling_reason`.
  @Test func wordMaskOverwritesGreenRowButPreservesSiblingReason() throws {
    let v = vocab(["s": 4, "θ": 5])
    let src = lp([[0: 0.999], [4: 0.99], [0: 0.999], [0: 0.997, 5: 0.002], [0: 0.997, 5: 0.002], [0: 0.999]])
    let take = lp([[0: 0.999], [4: 0.99], [0: 0.999], [0: 0.997, 5: 0.002], [0: 0.997, 5: 0.002], [0: 0.999]])
    let request = XeusRequest(words: [.init(id: "w1", text: "test2", variants: [["s", "θ"]])])
    let evidence = try XeusRuntime.assembleFromLogits(source: src, take: take, hiddenSource: nil,
      hiddenTake: nil, vocab: v, request: request, sourceDuration: Double(src.count) * 0.02,
      takeDuration: Double(take.count) * 0.02, thresholds: .standard, head: nil)
    let phones = evidence.words[0].phones
    let aRow = try #require(phones.first { $0.expected == "s" })
    let bRow = try #require(phones.first { $0.expected == "θ" })
    #expect(aRow.takeStatus == "correct")  // would-be-green before the mask …
    #expect(aRow.status == "uncertain")
    #expect(aRow.reason == "referenceNotConfident")
    #expect(bRow.status == "uncertain")
    #expect(bRow.reason == "referenceWeak")  // sibling keeps its own specific reason
  }

  /// Port of `test_cannot_distinguish_always_overrides_a_correct_take`.
  @Test func cannotDistinguishAlwaysOverridesACorrectTake() throws {
    let v = vocab(["ɡ": 4, "ɹ": 5, "ɑː": 6, "ɑ": 7, "æ": 8, "s": 9])
    func vowel(_ t: Int) -> [[Int: Double]] {
      [[4: 0.99], [0: 0.99], [5: 0.99], [0: 0.99], [t: 0.99], [t: 0.99], [0: 0.99], [9: 0.99], [0: 0.99]]
    }
    let src = lp(vowel(8))   // source says [æ]
    let take = lp(vowel(7))  // take says [ɑ]
    let request = XeusRequest(words: [.init(id: "w", text: "garths", variants: [["g", "ɹ", "ɑː", "s"]])])
    let evidence = try XeusRuntime.assembleFromLogits(source: src, take: take, hiddenSource: nil,
      hiddenTake: nil, vocab: v, request: request, sourceDuration: 9 * 0.02, takeDuration: 9 * 0.02,
      thresholds: .standard, head: nil)
    let row = try #require(evidence.words.flatMap { $0.phones }.first { $0.expected == "ɑː" })
    #expect(row.licence == "cannotDistinguish")
    #expect(row.takeStatus == "correct")
    #expect(row.status == "uncertain")
    #expect(row.reason == "modelCannotDistinguish")
  }

  // MARK: - unsupported-target / lattice error paths (thrown, not preconditions)

  @Test func unsupportedUKTargetThrows() {
    let v = vocab()  // no real IPA -> 'θ' never encodes
    let request = XeusRequest(words: [.init(id: "w", text: "th", variants: [["θ"]])])
    let src = lp([[0: 0.99], [4: 0.99], [0: 0.99]])
    #expect(throws: XeusRuntimeError.unsupportedUKTarget("th")) {
      _ = try XeusRuntime.assembleFromLogits(source: src, take: src, hiddenSource: nil, hiddenTake: nil,
        vocab: v, request: request, sourceDuration: 0.06, takeDuration: 0.06, thresholds: .standard, head: nil)
    }
  }

  // MARK: - clip-level parity (the heart of the port)

  /// Thresholds pinned exactly as the calibration artifact `thresholds.json` the golden decisions
  /// were generated with (`assemble_from_logits` -> `load_thresholds()`): competitor is 1.8, NOT the
  /// code default `ln 6`.
  private var calibratedThresholds: XeusRuntime.Thresholds {
    XeusRuntime.Thresholds(support: 0.30, margin: Foundation.log(4), entropy: 0.55, competitor: 1.8, strength: 0.65)
  }

  @Test func okayClipMatchesGoldenExactly() throws {
    try assertClipParity(logits: "okay.logits.npy", decisions: "okay.decisions.json")
  }

  @Test func vestUKClipMatchesGoldenExactly() throws {
    try assertClipParity(logits: "vest-uk.logits.npy", decisions: "vest-uk.decisions.json")
  }

  @Test func fullSourceClipMatchesGoldenExactly() throws {
    try assertClipParity(logits: "full-source.logits.npy", decisions: "full-source.decisions.json")
  }

  /// Runs `assembleFromLogits` on the clip's real logits (source-self) with the calibrated
  /// thresholds and the real shipped vocab, then asserts per-phone `expected`/`status`/`reason` and
  /// the coverage counts match the golden decisions EXACTLY. Machine-dependent fields
  /// (inferenceSeconds/peakRSS/device/loadSeconds) are excluded per manifest.json.
  private func assertClipParity(logits: String, decisions: String) throws {
    let vocabURL = repoRoot.appendingPathComponent(
      "vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/ipa_vocab.json")
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))

    let lp = try Self.loadNpyF32(repoRoot.appendingPathComponent("ToSpeechTests/Fixtures/XeusNative/\(logits)"))
    let golden = try JSONSerialization.jsonObject(
      with: Data(contentsOf: repoRoot.appendingPathComponent("ToSpeechTests/Fixtures/XeusNative/\(decisions)")))
      as! [String: Any]
    let sourceDuration = (golden["sourceDuration"] as! NSNumber).doubleValue
    let takeDuration = (golden["takeDuration"] as! NSNumber).doubleValue
    let requestJSON = golden["request"] as! [String: Any]
    let words = (requestJSON["words"] as! [[String: Any]]).map { word in
      XeusRequest.Word(id: word["id"] as! String, text: word["text"] as! String,
        variants: (word["variants"] as! [[Any]]).map { $0.map { $0 as! String } })
    }
    let result = golden["result"] as! [String: Any]

    // Source-self clip goldens: source==take. Head/hidden play no role (none of these clips contain
    // a CONTRASTS_FOR phone realized outside the accepted class), so `head: nil` reproduces them.
    let evidence = try XeusRuntime.assembleFromLogits(source: lp, take: lp, hiddenSource: nil,
      hiddenTake: nil, vocab: vocab, request: XeusRequest(words: words), sourceDuration: sourceDuration,
      takeDuration: takeDuration, thresholds: calibratedThresholds, head: nil)

    // Per-phone expected/status/reason parity.
    let goldenWords = result["words"] as! [[String: Any]]
    #expect(evidence.words.count == goldenWords.count)
    for (wi, goldenWord) in goldenWords.enumerated() {
      let goldenPhones = goldenWord["phones"] as! [[String: Any]]
      let phones = evidence.words[wi].phones
      #expect(phones.count == goldenPhones.count, "\(logits) word \(wi) phone count")
      for (pi, goldenPhone) in goldenPhones.enumerated() {
        let phone = phones[pi]
        let gExpected = goldenPhone["expected"] as! String
        let gStatus = goldenPhone["status"] as! String
        let gReason = goldenPhone["reason"] as? String  // null -> nil
        #expect(phone.expected == gExpected, "\(logits) w\(wi)p\(pi) expected")
        #expect(phone.status == gStatus, "\(logits) w\(wi)p\(pi) status: got \(phone.status) want \(gStatus) (\(gExpected))")
        #expect(phone.reason == gReason, "\(logits) w\(wi)p\(pi) reason: got \(String(describing: phone.reason)) want \(String(describing: gReason)) (\(gExpected))")
      }
    }

    // Coverage parity (a pure function of the per-phone statuses).
    let allPhones = evidence.words.flatMap { $0.phones }
    let correct = allPhones.filter { $0.status == "correct" }.count
    let incorrect = allPhones.filter { $0.status == "likelyIncorrect" }.count
    let goldenCoverage = result["coverage"] as! [String: Any]
    #expect(allPhones.count == (goldenCoverage["total"] as! NSNumber).intValue, "\(logits) total")
    #expect(correct == (goldenCoverage["correct"] as! NSNumber).intValue, "\(logits) correct")
    #expect(incorrect == (goldenCoverage["incorrect"] as! NSNumber).intValue, "\(logits) incorrect")
    #expect(correct + incorrect == (goldenCoverage["scored"] as! NSNumber).intValue, "\(logits) scored")
  }

  // MARK: - minimal .npy loader (float32, C-order, v1.0/v2.0 header)

  /// Reads a NumPy `.npy` array of little-endian float32 (`<f4`), C-contiguous, 2-D `[frames, cols]`,
  /// into `[[Double]]`. Just enough of the format to load the Task 2 logit fixtures — the exact
  /// float32 values `dump_golden.py` saved (`.astype(np.float32)`), upcast to `Double`.
  static func loadNpyF32(_ url: URL) throws -> [[Double]] {
    let data = try Data(contentsOf: url)
    // The .npy magic is the single byte 0x93 followed by ASCII "NUMPY". Do NOT build this from
    // "\u{93}NUMPY".utf8 — U+0093 encodes to two UTF-8 bytes (0xC2 0x93), which never matches.
    precondition(data.count > 12 && Array(data.prefix(6)) == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59], "not a .npy file: \(url.lastPathComponent)")
    let major = data[6]
    let headerStart: Int
    let dataStart: Int
    if major == 1 {
      let headerLen = Int(data[8]) | (Int(data[9]) << 8)
      headerStart = 10
      dataStart = 10 + headerLen
    } else {
      let headerLen = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
      headerStart = 12
      dataStart = 12 + headerLen
    }
    let header = String(decoding: data[headerStart..<dataStart], as: UTF8.self)
    precondition(header.contains("'<f4'"), "expected little-endian float32 .npy: \(header)")
    precondition(header.contains("'fortran_order': False"), "expected C-order .npy: \(header)")

    // Parse `'shape': (F, C)` (or `(F, C,)`).
    guard let shapeRange = header.range(of: "'shape': (") else { preconditionFailure("no shape in .npy header") }
    let afterShape = header[shapeRange.upperBound...]
    guard let close = afterShape.firstIndex(of: ")") else { preconditionFailure("malformed shape in .npy header") }
    let dims = afterShape[..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    precondition(dims.count == 2, "expected 2-D .npy shape, got \(dims)")
    let frames = dims[0], cols = dims[1]

    var result = [[Double]]()
    result.reserveCapacity(frames)
    data.withUnsafeBytes { raw in
      for f in 0..<frames {
        var row = [Double](repeating: 0, count: cols)
        for c in 0..<cols {
          let value = raw.loadUnaligned(fromByteOffset: dataStart + (f * cols + c) * 4, as: Float32.self)
          row[c] = Double(value)
        }
        result.append(row)
      }
    }
    return result
  }
}
