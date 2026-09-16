import Foundation

/// Runtime decision pipeline — a 1:1 port of `scripts/assessment/phoneticxeus/runtime.py` lines
/// 83-146 (`runs`, `_realization`, `_pooled`, `_span`, `stage_a`, `apply_head_take`) and 154-219
/// (`assemble_from_logits`), including the merged per-word native-competence mask (`_native_ok` +
/// the overwrite loop, runtime.py lines 186-204).
///
/// This ties Tasks 4-8 together into the full scorer: it consumes `XeusInventory` (units/allophone
/// tables), `XeusLattice` (`alignVariants`/`alignUnits`), `XeusAssess` (`assessUnits`/`greedy`/
/// `coverage`), `XeusCTC` (via those), and `XeusContrastHead` (the logistic RP-contrast head), and
/// produces a `PhoneticXeusEvidence` — the exact struct `PhoneticXeusAdapter.convert` consumes.
///
/// RESILIENCE: the deeper CTC/lattice/assess functions trap (`precondition`) on invalid ids/`lp`
/// (carry-forward ruling from Tasks 5/6 — they only ever see valid ids/log-probs on this path). But
/// `assembleFromLogits`/`stageA` themselves can fail an assessment *gracefully*: Python raises
/// `ValueError` ('unsupported UK target', 'source target lattice could not align'), and this port
/// raises those as THROWN `XeusRuntimeError`s (not preconditions), so Task 10's orchestrator can
/// surface a failed job instead of crashing.
///
/// SCOPE NOTE: `runtime.assemble_from_logits` also calls `reference.diagnostics(...)` (runtime.py
/// line 206) to attach a per-phone `diagnostic` and a top-level `reference` block. That is
/// `reference.py`'s DTW/JSD diagnostic layer, out of scope for this task (the brief's port range is
/// runtime.py 95-188 + the merged mask); every per-phone `diagnostic` is therefore `nil` and the
/// top-level `reference` is `nil` here. None of it feeds back into a phone's status/reason/coverage
/// (those are fully determined by the code below), which is the parity contract that matters.
enum XeusRuntime {
  /// Port of `runtime.py`'s module-level `REVISION` constant.
  static let revision = "8d83dee94817a07dc150f87d08f7e0ee01bdb66d"
  /// Port of `reference.py`'s `REFERENCE_POLICY` (attached as `referencePolicy` by `assemble_from_logits`).
  static let referencePolicy = "xeus-reference-diagnostics-v2"

  typealias Thresholds = XeusAssess.Thresholds
  typealias AssessRow = XeusAssess.AssessRow
  typealias Unit = XeusInventory.Unit

  /// One frame-run of the greedy (argmax) decode: `(tokenID, startFrame, endFrame)` — port of the
  /// tuples `runs(lp)` yields.
  struct Run: Equatable { let token: Int; let start: Int; let end: Int }

  /// Result of `stage_a` (runtime.py returns `dict(anchors,allowed,licences,realizations,rows)`).
  struct StageA {
    var anchors: [[Int]]
    var allowed: [[[Int]]]
    var licences: [String]
    var realizations: [[Int]]
    var rows: [AssessRow]
  }

  // MARK: - runs (runtime.py:83-89)

  /// Port of `runs(lp)`: collapse consecutive identical per-frame argmax ids into runs and keep the
  /// non-blank/non-reserved (`>= 4`) ones as `(id, start, end)`.
  static func runs(_ lp: [[Double]]) -> [Run] {
    guard !lp.isEmpty else { return [] }
    let ids: [Int] = lp.map { row in
      var bestIndex = 0
      var bestValue = row[0]
      for i in 1..<row.count where row[i] > bestValue { bestValue = row[i]; bestIndex = i }
      return bestIndex
    }
    var out: [Run] = []
    var start = 0
    for end in 1...ids.count {
      if end == ids.count || ids[end] != ids[start] {
        if ids[start] >= 4 { out.append(Run(token: ids[start], start: start, end: end)) }
        start = end
      }
    }
    return out
  }

  // MARK: - _realization (runtime.py:91-93)

  /// Port of `_realization(span, all_runs)`: the ordered token ids of every run overlapping `span`
  /// (`s < b and e > a`); `nil`/empty span -> `[]`.
  static func realization(_ span: (Int, Int)?, _ allRuns: [Run]) -> [Int] {
    guard let (a, b) = span else { return [] }
    return allRuns.filter { $0.start < b && $0.end > a }.map { $0.token }
  }

  // MARK: - _pooled (runtime.py:95-99)

  /// Port of `_pooled(hidden,row,head)`: mean-pool the hidden state over the row's `[windowStart,
  /// windowEnd)` frames, or `nil` when there is no hidden state, no window, or a head/hidden
  /// dimension mismatch. `hidden.mean(0)` runs in the hidden dtype (float32), matching Python's
  /// `hidden[a:b].mean(0)` on the float32 encoder output.
  static func pooled(_ hidden: [[Float]]?, _ row: AssessRow, _ head: XeusContrastHead?) -> [Float]? {
    guard let hidden = hidden, let a = row.windowStart, let b = row.windowEnd, b > a else { return nil }
    let dim = hidden.first?.count ?? 0
    if let head = head, dim != head.dim { return nil }
    guard dim > 0 else { return nil }
    var sum = [Float](repeating: 0, count: dim)
    for t in a..<b {
      let r = hidden[t]
      for k in 0..<dim { sum[k] += r[k] }
    }
    let n = Float(b - a)
    return sum.map { $0 / n }
  }

  // MARK: - _span (runtime.py:101-103)

  /// Port of `_span(row, step=.02)`: the row's emission frame range `(a, b)` (rounded from
  /// `emissionStart`/`emissionEnd`), or `nil` when either bound is absent or the range is empty.
  /// Uses round-half-to-even to match Python's `int(round(...))` (banker's rounding).
  static func span(_ row: AssessRow, step: Double = 0.02) -> (Int, Int)? {
    guard let emissionStart = row.emissionStart, let emissionEnd = row.emissionEnd else { return nil }
    let a = Int((emissionStart / step).rounded(.toNearestOrEven))
    let b = Int((emissionEnd / step).rounded(.toNearestOrEven))
    return b > a ? (a, b) : nil
  }

  // MARK: - stage_a (runtime.py:105-133)

  /// Port of `stage_a`. Reference licensing: discover each unit's realized token run, license it
  /// `accepted`/`classD`/`unmapped`, consult the contrast head on the SOURCE (skipping `classD`),
  /// then run the final demotion gate (accepted-but-not-correct -> `weak`; likelyIncorrect /
  /// negative-margin / no-start -> `weak`).
  ///
  /// Throws `XeusRuntimeError.sourceTargetLatticeCouldNotAlign` when the unit lattice cannot align
  /// (`align_units` -> `None`), mirroring Python's `raise ValueError('source target lattice could
  /// not align')`.
  static func stageA(
    _ source: [[Double]],
    _ units: [Unit],
    _ vocab: [String: Int],
    duration: Double,
    head: XeusContrastHead?,
    hidden: [[Float]]?,
    thresholds: Thresholds
  ) throws -> StageA {
    guard let discovery = XeusLattice.alignUnits(source, units, extra: units.map { $0.cond }) else {
      throw XeusRuntimeError.sourceTargetLatticeCouldNotAlign
    }
    let rr = runs(source)
    var allowed: [[[Int]]] = []
    var licences: [String] = []
    var realizations: [[Int]] = []
    for (i, u) in units.enumerated() {
      // discovery[i] is a non-nil [start, end] span (align_units returned a full alignment).
      let R = realization((discovery[i][0], discovery[i][1]), rr)
      let lic: String
      let al: [[Int]]
      if R.isEmpty || u.allowed.contains(R) {
        lic = "accepted"; al = u.allowed
      } else if u.cond.contains(R) {
        lic = "classD"; al = u.allowed + [R]
      } else {
        lic = "unmapped"; al = u.allowed
      }
      allowed.append(al); licences.append(lic); realizations.append(R)
    }

    var rows = XeusAssess.assessUnits(source, units, allowed, vocab, duration: duration, thresholds: thresholds)

    // Contrast-head consult on the SOURCE (runtime.py:117-124). Skips `classD` units. The `contrast`
    // dict Python writes onto the source row is discarded here: it never propagates to the take row
    // nor into any status/reason/coverage output; only the licence change it drives is kept.
    for i in 0..<units.count {
      let u = units[i]
      guard u.display.count == 1, let display = u.display.first,
        let names = XeusContrastHead.CONTRASTS_FOR[display], !names.isEmpty,
        rows[i].status != "correct", licences[i] != "classD" else { continue }
      guard let closest = rows[i].closestPhone,
        XeusContrastHead.COMPETITORS[display]?.contains(closest) == true else { continue }
      let pooledValue = pooled(hidden, rows[i], head)
      guard let head = head, let pooledValue = pooledValue else {
        licences[i] = "cannotDistinguish"; continue
      }
      let p = head.probability(display, pooledValue)
      let d = XeusContrastHead.decide(p)
      licences[i] = d == "uk" ? "head" : (d == "ambiguous" ? "weak" : "unmapped")
    }

    // Final demotion gate (runtime.py:125-132).
    for i in 0..<rows.count {
      guard licences[i] == "accepted" || licences[i] == "classD" else { continue }
      if licences[i] == "accepted", rows[i].status != "correct" { licences[i] = "weak"; continue }
      if rows[i].status == "likelyIncorrect" || (rows[i].logMargin ?? 0) < 0 || rows[i].start == nil {
        licences[i] = "weak"
      }
    }

    return StageA(anchors: discovery, allowed: allowed, licences: licences, realizations: realizations, rows: rows)
  }

  // MARK: - apply_head_take (runtime.py:135-146)

  /// Port of `apply_head_take`. On the TAKE side, re-arbitrate contrast units through the head:
  /// `uk` -> `correct`/`contrastHead`, `us` -> `likelyIncorrect` (with the US label as
  /// `closestPhone`), `ambiguous` -> `uncertain`/`ambiguous`; no head/pooled -> `uncertain`/
  /// `modelCannotDistinguish`. INCLUDES the `classD` skip (runtime.py:137 `... or
  /// licences[i]=='classD': continue`) that mirrors `stage_a`'s own skip so a `classD`-licensed
  /// unit is never flipped to red by the head.
  ///
  /// Returns the mutated rows plus a parallel `contrasts` array (Python writes `row['contrast']`;
  /// `AssessRow` has no such field, so the take-side contrast — which DOES surface in the output and
  /// in `PhoneticXeusAdapter.quality` — is carried alongside).
  static func applyHeadTake(
    _ units: [Unit],
    _ rows: [AssessRow],
    _ licences: [String],
    head: XeusContrastHead?,
    hidden: [[Float]]?
  ) -> (rows: [AssessRow], contrasts: [XeusContrast?]) {
    var rows = rows
    var contrasts = [XeusContrast?](repeating: nil, count: rows.count)
    for i in 0..<rows.count {
      let u = units[i]
      guard u.display.count == 1, let display = u.display.first,
        let names = XeusContrastHead.CONTRASTS_FOR[display], !names.isEmpty,
        rows[i].status != "correct", licences[i] != "classD" else { continue }
      guard let closest = rows[i].closestPhone,
        XeusContrastHead.COMPETITORS[display]?.contains(closest) == true else { continue }
      let pooledValue = pooled(hidden, rows[i], head)
      guard let head = head, let pooledValue = pooledValue else {
        rows[i].status = "uncertain"; rows[i].reason = "modelCannotDistinguish"; continue
      }
      let p = head.probability(display, pooledValue)
      let d = XeusContrastHead.decide(p)
      contrasts[i] = XeusContrast(name: names.joined(separator: "+"), pUK: round4(p), decision: d)
      if d == "uk" {
        rows[i].status = "correct"; rows[i].reason = "contrastHead"
      } else if d == "us" {
        rows[i].status = "likelyIncorrect"; rows[i].reason = nil
        rows[i].closestPhone = XeusContrastHead.US_LABEL[display]
      } else {
        rows[i].status = "uncertain"; rows[i].reason = "ambiguous"
      }
    }
    return (rows, contrasts)
  }

  // MARK: - assemble_from_logits (runtime.py:154-219)

  /// Port of `assemble_from_logits` (+ the merged per-word native-competence mask). Selects source
  /// variants, builds units, runs `stage_a` on the source, assesses + head-arbitrates the take,
  /// stamps every reference-licensing field, applies the hard per-word mask, expands to phone rows,
  /// and packages a `PhoneticXeusEvidence`.
  ///
  /// Throws `XeusRuntimeError.unsupportedUKTarget` (Python `raise ValueError('unsupported UK target:
  /// '+word['text'])`) when a word has no encodable variant, and
  /// `XeusRuntimeError.sourceTargetLatticeCouldNotAlign` (Python `raise ValueError('source target
  /// lattice could not align')`) when the source variant lattice or `stage_a`'s unit lattice cannot
  /// align.
  static func assembleFromLogits(
    source: [[Double]],
    take: [[Double]],
    hiddenSource: [[Float]]?,
    hiddenTake: [[Float]]?,
    vocab: [String: Int],
    request: XeusRequest,
    sourceDuration: Double,
    takeDuration: Double,
    thresholds: Thresholds,
    head: XeusContrastHead?
  ) throws -> PhoneticXeusEvidence {
    let words = request.words

    // valid=[v for v in word['variants'] if v and all(encode(p,vocab) for p in v)]
    var variants: [[[String]]] = []
    for word in words {
      let valid = word.variants.filter { v in
        !v.isEmpty && v.allSatisfy { XeusInventory.encode($0, vocab) != nil }
      }
      guard !valid.isEmpty else { throw XeusRuntimeError.unsupportedUKTarget(word.text) }
      variants.append(valid)
    }

    // alignment=align_variants(source,variants,vocab); default options = accepted(phone, vocab).
    let placeholderWords: [[[Int]]] = variants.map { word in word.map { Array(0..<$0.count) } }
    guard let alignment = XeusLattice.alignVariants(source, placeholderWords, options: { wi, vi, pi in
      XeusInventory.accepted(variants[wi][vi][pi], vocab)
    }) else {
      throw XeusRuntimeError.sourceTargetLatticeCouldNotAlign
    }

    // selected=[v[i] for v,i in zip(variants,alignment[0])]
    let selected: [[String]] = zip(variants, alignment.selected).map { variantList, index in variantList[index] }
    let units = try XeusInventory.buildUnits(zip(words, selected).map { ($0.id, $1) }, vocab)
    let inverse = invertVocab(vocab)

    let a = try stageA(source, units, vocab, duration: sourceDuration, head: head, hidden: hiddenSource, thresholds: thresholds)
    let takeAssessed = XeusAssess.assessUnits(take, units, a.allowed, vocab, duration: takeDuration, thresholds: thresholds)
    let (takeRows, takeContrasts) = applyHeadTake(units, takeAssessed, a.licences, head: head, hidden: hiddenTake)
    let tr = runs(take)

    // Per-unit reference-licensing fields + licence-driven status/reason overwrite (runtime.py:170-184).
    var assembled: [AssembledUnit] = []
    assembled.reserveCapacity(units.count)
    for i in 0..<units.count {
      let u = units[i]
      let trow = takeRows[i]
      let lic = a.licences[i]
      let R = a.realizations[i]
      let T = realization(span(trow), tr)
      let src = a.rows[i]

      // takeStatus/takeReason are captured from the (post-head) take row BEFORE the licence overwrite.
      let takeStatus = trow.status
      let takeReason = trow.reason
      var status = trow.status
      var reason = trow.reason

      let licensedRealization = (lic == "classD" || lic == "head") && !R.isEmpty
        ? R.map { inverse[$0]! }.joined(separator: " ") : nil
      let referenceRealization = R.isEmpty ? "" : R.map { inverse[$0]! }.joined(separator: " ")
      let referenceMatch = !R.isEmpty && R == T

      if lic == "unmapped" {
        status = "uncertain"; reason = "referenceUnmapped"
      } else if lic == "weak" {
        status = "uncertain"; reason = "referenceWeak"
      } else if lic == "cannotDistinguish" {
        status = "uncertain"; reason = "modelCannotDistinguish"
      }

      assembled.append(AssembledUnit(
        status: status, reason: reason, start: trow.start, end: trow.end,
        expectedProbability: trow.expectedProbability, logMargin: trow.logMargin,
        closestPhone: trow.closestPhone, confidence: trow.confidence,
        expectedTokenProbability: trow.expectedTokenProbability, contrast: takeContrasts[i],
        unitID: u.id, licence: lic, licensedRealization: licensedRealization,
        referenceRealization: referenceRealization, referenceStatus: src.status,
        takeStatus: takeStatus, takeReason: takeReason, referenceMatch: referenceMatch,
        sourceStart: src.start, sourceEnd: src.end, sourceStatus: src.status,
        display: u.display, word: u.word))
    }

    // Hard per-word native-competence mask (runtime.py:186-204). A word may show a red/green phone
    // only if the native reference confirmed EVERY unit of that word; otherwise the whole word is
    // grayed. Already-uncertain rows keep their specific reason.
    func nativeOK(_ i: Int) -> Bool {
      let lic = a.licences[i]
      if lic == "accepted" { return a.rows[i].status == "correct" }
      return lic == "classD" || lic == "head"
    }
    var wordOrder: [String] = []
    var wordUnits: [String: [Int]] = [:]
    for i in 0..<units.count {
      let w = units[i].word
      if wordUnits[w] == nil { wordOrder.append(w) }
      wordUnits[w, default: []].append(i)
    }
    for wid in wordOrder {
      let idxs = wordUnits[wid]!
      if idxs.allSatisfy({ nativeOK($0) }) { continue }
      for i in idxs where assembled[i].status == "correct" || assembled[i].status == "likelyIncorrect" {
        assembled[i].status = "uncertain"; assembled[i].reason = "referenceNotConfident"
      }
    }

    // expand_rows + per-word results (runtime.py:205-213). Units are grouped by word contiguously
    // (build_units emits them in word order), so each word consumes its own units' display phones.
    var resultWords: [PhoneticXeusEvidence.Word] = []
    var unitCursor = 0
    for (wi, word) in words.enumerated() {
      let variant = selected[wi]
      var phones: [PhoneticXeusPhoneEvidence] = []
      var consumed = 0
      while consumed < variant.count {
        let unit = assembled[unitCursor]
        for phone in unit.display { phones.append(unit.phone(expected: phone)) }
        consumed += unit.display.count
        unitCursor += 1
      }
      resultWords.append(PhoneticXeusEvidence.Word(id: word.id, variant: variant, phones: phones))
    }

    let takeGreedy = XeusAssess.greedy(take, inverse, step: 0.02, duration: takeDuration)
    let sourceGreedy = XeusAssess.greedy(source, inverse, step: 0.02, duration: sourceDuration)

    return PhoneticXeusEvidence(
      revision: revision, policy: XeusAssess.policy, mapping: XeusInventory.mapping,
      device: "cpu", dtype: "float32", duration: takeDuration, sourceDuration: sourceDuration,
      sourceShape: [source.count, source.first?.count ?? 0],
      takeShape: [take.count, take.first?.count ?? 0],
      inferenceSeconds: 0, loadSeconds: 0, peakRSS: 0, words: resultWords,
      recognizedPhones: takeGreedy.map { RecognizedPhone(symbol: $0.symbol, start: $0.start, end: $0.end, posterior: $0.posterior) },
      sourceRecognizedPhones: sourceGreedy.map { RecognizedPhone(symbol: $0.symbol, start: $0.start, end: $0.end, posterior: $0.posterior) },
      reference: nil, deliveryError: nil, referencePolicy: referencePolicy, contrastHead: nil)
  }

  // MARK: - private helpers

  /// One unit's assembled state after `stage_a` + `apply_head_take` + the licence-driven overwrite,
  /// before `expand_rows` fans it out to one `PhoneticXeusPhoneEvidence` per display phone.
  private struct AssembledUnit {
    var status: String
    var reason: String?
    var start: Double?
    var end: Double?
    var expectedProbability: Double?
    var logMargin: Double?
    var closestPhone: String?
    var confidence: Double?
    var expectedTokenProbability: Double?
    var contrast: XeusContrast?
    var unitID: String
    var licence: String
    var licensedRealization: String?
    var referenceRealization: String
    var referenceStatus: String?
    var takeStatus: String?
    var takeReason: String?
    var referenceMatch: Bool
    var sourceStart: Double?
    var sourceEnd: Double?
    var sourceStatus: String?
    var display: [String]
    var word: String

    /// `expand_rows` copy: one phone row carrying this unit's fields plus its display `expected`.
    func phone(expected: String) -> PhoneticXeusPhoneEvidence {
      PhoneticXeusPhoneEvidence(
        expected: expected, status: status, reason: reason, start: start, end: end,
        expectedProbability: expectedProbability, logMargin: logMargin, closestPhone: closestPhone,
        confidence: confidence, sourceStart: sourceStart, sourceEnd: sourceEnd,
        sourceStatus: sourceStatus, diagnostic: nil, expectedTokenProbability: expectedTokenProbability,
        unitID: unitID, licence: licence, licensedRealization: licensedRealization,
        referenceRealization: referenceRealization, referenceStatus: referenceStatus,
        takeStatus: takeStatus, takeReason: takeReason, referenceMatch: referenceMatch,
        contrast: contrast)
    }
  }

  /// Port of `round(p, 4)` — banker's (round-half-to-even) rounding to 4 decimals, matching Python.
  private static func round4(_ value: Double) -> Double {
    (value * 10000).rounded(.toNearestOrEven) / 10000
  }

  /// Port of `inverse={i:s for s,i in vocab.items()}` — identical tie-break policy to
  /// `XeusAssess.invertVocab` (private there, duplicated here since Swift `private` is file-scoped):
  /// prefer a real IPA name over the synthetic `x<id>` placeholder, else the lexicographically
  /// smaller name, so a placeholder-filled test vocab inverts to the same names Python's
  /// insertion-order comprehension produces.
  private static func invertVocab(_ vocab: [String: Int]) -> [Int: String] {
    var inverse: [Int: String] = [:]
    for (symbol, id) in vocab {
      guard let existing = inverse[id] else { inverse[id] = symbol; continue }
      let placeholder = "x\(id)"
      if existing == placeholder, symbol != placeholder {
        inverse[id] = symbol
      } else if existing != placeholder, symbol != placeholder, symbol < existing {
        inverse[id] = symbol
      }
    }
    return inverse
  }
}

/// The scoring request `assembleFromLogits` consumes — a native mirror of the JSON `request` shape
/// (`{'words':[{'id','text','variants':[[phone,...],...]}]}`) that `runtime.assemble_from_logits`
/// reads. Only the fields the decision pipeline uses are modeled (the source/take audio paths are
/// resolved before inference and are not needed here).
struct XeusRequest: Equatable {
  struct Word: Equatable {
    let id: String
    let text: String
    let variants: [[String]]
  }
  let words: [Word]
}

/// Port of the two `ValueError`s `assemble_from_logits`/`stage_a` raise. These are THROWN (not
/// preconditions) so an unassessable job fails gracefully rather than crashing the process — see the
/// RESILIENCE note on `XeusRuntime`.
enum XeusRuntimeError: Error, LocalizedError, Equatable {
  case unsupportedUKTarget(String)
  case sourceTargetLatticeCouldNotAlign

  var errorDescription: String? {
    switch self {
    case .unsupportedUKTarget(let word): return "unsupported UK target: \(word)"
    case .sourceTargetLatticeCouldNotAlign: return "source target lattice could not align"
    }
  }
}
