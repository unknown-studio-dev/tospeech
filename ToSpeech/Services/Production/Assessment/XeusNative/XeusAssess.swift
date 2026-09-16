import Foundation

/// GOP assessment, confusion gate, and coverage — a 1:1 port of
/// `scripts/assessment/phoneticxeus/evidence.py` lines 245-254 (`greedy`), 256-303
/// (`assess_units`), 305-310 (`expand_rows`), 312-318 (`assess_phones`) and 320-326 (`coverage`).
///
/// UK CTC evidence, not calibrated pronunciation accuracy: this is the decision policy built on
/// top of `XeusInventory` (the UK phone/allophone token-sequence tables, `Unit`, `CONFUSION`),
/// `XeusCTC` (`path`/`realizationLikelihood`) and `XeusLattice` (`alignUnits`).
///
/// `XeusCTC.path` traps (`precondition`) on any special/unmapped target id (`< 4` or `>=` vocab
/// size). Every `path` call site below only ever passes ids from `XeusInventory.accepted`/
/// `conditional`-derived sequences (chosen/al), the UK inventory (`XeusInventory.encode`, which
/// itself only emits ids `>= 4`), or the top-argmax competitor ids (explicitly filtered `>= 4`
/// below) — matching Python's own invariant that `assess_units` never scores a blank/reserved id.
enum XeusAssess {
  /// Port of `evidence.py`'s module-level `POLICY` constant.
  static let policy = "xeus-uk-decision-v6-word-gated"

  /// Decision thresholds — a 1:1 port of `evidence.py`'s `THRESHOLDS = dict(support=.30,
  /// margin=math.log(4), entropy=.55, competitor=math.log(6), strength=.65)`.
  struct Thresholds: Equatable {
    var support: Double
    var margin: Double
    var entropy: Double
    var competitor: Double
    var strength: Double

    init(
      support: Double = 0.30, margin: Double = Foundation.log(4), entropy: Double = 0.55,
      competitor: Double = Foundation.log(6), strength: Double = 0.65
    ) {
      self.support = support
      self.margin = margin
      self.entropy = entropy
      self.competitor = competitor
      self.strength = strength
    }

    static let standard = Thresholds()
  }

  /// One unit's windowed CTC evidence — mirrors the Python dict `assess_units` builds per unit
  /// (`evidence.py` lines 298-302: status/reason/start/end/emissionStart/emissionEnd/
  /// windowStart/windowEnd/expectedProbability/expectedTokenProbability/expectedLogLikelihood/
  /// alternativeLogLikelihood/deletionLogLikelihood/logMargin/closestPhone/confidence/chosen).
  ///
  /// All fields beyond `status`/`reason` are `nil` for the three alignment-failure short circuits
  /// (`reason == "alignment"`), matching the 2-key Python dict
  /// (`dict(status='uncertain',reason='alignment')`) those branches return instead of the full
  /// 17-key dict.
  struct AssessRow: Equatable {
    var status: String
    var reason: String?
    var start: Double?
    var end: Double?
    var emissionStart: Double?
    var emissionEnd: Double?
    var windowStart: Int?
    var windowEnd: Int?
    var expectedProbability: Double?
    var expectedTokenProbability: Double?
    var expectedLogLikelihood: Double?
    var alternativeLogLikelihood: Double?
    var deletionLogLikelihood: Double?
    var logMargin: Double?
    var closestPhone: String?
    var confidence: Double?
    var chosen: [String]?

    init(
      status: String, reason: String? = nil, start: Double? = nil, end: Double? = nil,
      emissionStart: Double? = nil, emissionEnd: Double? = nil, windowStart: Int? = nil,
      windowEnd: Int? = nil, expectedProbability: Double? = nil,
      expectedTokenProbability: Double? = nil, expectedLogLikelihood: Double? = nil,
      alternativeLogLikelihood: Double? = nil, deletionLogLikelihood: Double? = nil,
      logMargin: Double? = nil, closestPhone: String? = nil, confidence: Double? = nil,
      chosen: [String]? = nil
    ) {
      self.status = status
      self.reason = reason
      self.start = start
      self.end = end
      self.emissionStart = emissionStart
      self.emissionEnd = emissionEnd
      self.windowStart = windowStart
      self.windowEnd = windowEnd
      self.expectedProbability = expectedProbability
      self.expectedTokenProbability = expectedTokenProbability
      self.expectedLogLikelihood = expectedLogLikelihood
      self.alternativeLogLikelihood = alternativeLogLikelihood
      self.deletionLogLikelihood = deletionLogLikelihood
      self.logMargin = logMargin
      self.closestPhone = closestPhone
      self.confidence = confidence
      self.chosen = chosen
    }

    /// Port of `dict(status='uncertain',reason='alignment')` — the alignment-failure short
    /// circuit shared by all three early-return sites in `assess_units` (no anchors, an empty
    /// window, or an unaligned `chosen` path).
    static func alignmentFailure() -> AssessRow { AssessRow(status: "uncertain", reason: "alignment") }
  }

  /// One expanded phone-level row — mirrors `expand_rows`'s `r=dict(row);
  /// r.update(expected=phone,unitID=unit.id,shared=len(unit.display)>1)`.
  ///
  /// Exposes every `AssessRow` field directly via `@dynamicMemberLookup` (so `row.status`/
  /// `row.closestPhone`/... read exactly like the Python dict's `row['status']`/
  /// `row['closestPhone']`/...), plus its own `expected`/`unitID`/`shared`.
  @dynamicMemberLookup
  struct PhoneRow: Equatable {
    var row: AssessRow
    var expected: String
    var unitID: String
    var shared: Bool

    subscript<T>(dynamicMember keyPath: KeyPath<AssessRow, T>) -> T { row[keyPath: keyPath] }
  }

  /// Port of `evidence.py`'s `coverage(rows)` result dict.
  struct Coverage: Equatable {
    var total: Int
    var scored: Int
    var correct: Int
    var incorrect: Int
    var unassessed: Int
    var coverage: Double
  }

  /// Port of `evidence.py`'s `greedy(lp, inverse, step, duration)`'s per-run emission dict.
  struct GreedyEmission: Equatable {
    var symbol: String
    var start: Double
    var end: Double
    var posterior: Double
  }

  // MARK: - greedy (evidence.py:245-254)

  /// Greedy (argmax-per-frame) decoding: collapses consecutive identical argmax ids into runs and
  /// emits one entry per non-blank/non-reserved (`>= 4`) run, with the mean posterior probability
  /// of that id across the run's frames.
  static func greedy(_ lp: [[Double]], _ inverse: [Int: String], step: Double, duration: Double) -> [GreedyEmission] {
    guard !lp.isEmpty else { return [] }
    let ids: [Int] = lp.map { row in
      var bestIndex = 0
      var bestValue = row[0]
      for i in 1..<row.count where row[i] > bestValue { bestValue = row[i]; bestIndex = i }
      return bestIndex
    }
    var result: [GreedyEmission] = []
    var start = 0
    for end in 1...ids.count {
      if end == ids.count || ids[end] != ids[start] {
        let idx = ids[start]
        if idx >= 4 {
          var sum = 0.0
          for t in start..<end { sum += exp(lp[t][idx]) }
          let posterior = sum / Double(end - start)
          result.append(GreedyEmission(
            symbol: inverse[idx]!, start: Double(start) * step,
            end: min(Double(end) * step, duration), posterior: posterior))
        }
        start = end
      }
    }
    return result
  }

  // MARK: - assess_units (evidence.py:256-303)

  /// Windowed CTC evidence per unit. `allowed[i]` is the licensed token-sequence set of unit `i`
  /// (usually `units[i].allowed`, but callers may pass extra licensed sequences beyond it, e.g.
  /// Stage-A-licensed Class-D realizations — grading always uses `allowed[i]`, never
  /// `units[i].allowed` directly).
  ///
  /// Localization may use unlicensed class-D sequences (`unit.cond`) plus any sequences in
  /// `allowed[i]` beyond `unit.allowed`, so a learner realization such as an unlicensed rhotic
  /// vowel still lands in its own window; grading uses `allowed[i]` only.
  static func assessUnits(
    _ lp: [[Double]],
    _ units: [XeusInventory.Unit],
    _ allowed: [[[Int]]],
    _ vocab: [String: Int],
    duration: Double,
    thresholds: Thresholds = .standard,
    step: Double = 0.02
  ) -> [AssessRow] {
    // `XeusLattice.alignUnits` -> `alignVariants` already runs the same `validate(lp)`
    // precondition Python calls explicitly at the top of `assess_units`; no separate call needed
    // here — an invalid `lp` traps one call deeper, with the same crash-on-invalid-usage effect.
    let extra: [[[Int]]] = zip(units, allowed).map { unit, al in
      let allowedSet = Set(unit.allowed)
      return dedupeSequences(unit.cond + al.filter { !allowedSet.contains($0) })
    }
    guard let anchors = XeusLattice.alignUnits(lp, units, extra: extra) else {
      return units.map { _ in .alignmentFailure() }
    }

    var bounds = [anchors[0][0]]
    for i in 0..<(anchors.count - 1) { bounds.append((anchors[i][1] + anchors[i + 1][0]) / 2) }
    bounds.append(anchors[anchors.count - 1][1])

    let inverse = invertVocab(vocab)
    // `inventory={p:encode(p,vocab) for p in UK}` — only the UK phones that actually encode in
    // this vocab (`encode` returning `nil` is Python's `None`, filtered out by `if seq` when
    // `scores` is built below; pre-filtering here is equivalent since `encode` never returns an
    // empty-but-non-nil sequence).
    let inventoryOrder: [(phone: String, seq: [Int])] = XeusInventory.UK.compactMap { phone in
      XeusInventory.encode(phone, vocab).map { (phone, $0) }
    }
    let vocabSize = lp[0].count

    var output: [AssessRow] = []
    for index in 0..<units.count {
      let unit = units[index]
      let al = allowed[index]
      let begin = anchors[index][0]
      let end = anchors[index][1]
      let lo = bounds[index]
      let hi = bounds[index + 1]
      guard hi > lo else { output.append(.alignmentFailure()); continue }
      let window = Array(lp[lo..<hi])

      let chosen = argmax(al) { XeusCTC.path(window, $0).score }
      let expectedLog = XeusCTC.realizationLikelihood(window, al)

      // top=[int(i) for i in np.argsort(window.max(0))[-12:] if i>=4]
      var colMax = [Double](repeating: -Double.infinity, count: vocabSize)
      for row in window {
        for i in 0..<vocabSize where row[i] > colMax[i] { colMax[i] = row[i] }
      }
      // Swift's `sorted` is stable; numpy's default `argsort` is not. This only matters for
      // exactly-tied column maxima (only reachable with synthetic all-equal competitor
      // probabilities, e.g. a test fixture spreading weight evenly across many ids): the
      // *decision* (status/reason/margin/support/...) is identical either way, since tied
      // competitors share the same CTC score by construction — only which exact tied id gets
      // reported as `closestPhone` can differ from the reference Python run in that edge case.
      let order = (0..<vocabSize).sorted { colMax[$0] < colMax[$1] }
      let top = order.suffix(12).filter { $0 >= 4 }

      // candidates=dict(inventory); candidates.update({inverse[i]:[i] for i in top}) — an
      // insertion-ordered map: UK-inventory phones first (in UK-list order), then any `top` id
      // whose vocab name isn't already an inventory key, appended in ascending-score order;
      // a `top` id whose name IS already a key only overwrites that key's value in place.
      var candidateOrder: [String] = []
      var candidateSeq: [String: [Int]] = [:]
      for (phone, seq) in inventoryOrder {
        if candidateSeq[phone] == nil { candidateOrder.append(phone) }
        candidateSeq[phone] = seq
      }
      for id in top {
        let name = inverse[id]!
        if candidateSeq[name] == nil { candidateOrder.append(name) }
        candidateSeq[name] = [id]
      }

      // scores={p:path(window,seq) for p,seq in candidates.items() if seq and seq not in al}
      let allowedSet = Set(al)
      var scoreOrder: [String] = []
      var scoreValue: [String: Double] = [:]
      for phone in candidateOrder {
        let seq = candidateSeq[phone]!
        guard !seq.isEmpty, !allowedSet.contains(seq) else { continue }
        scoreOrder.append(phone)
        scoreValue[phone] = XeusCTC.path(window, seq).score
      }
      let observed = argmax(scoreOrder) { scoreValue[$0]! }
      let alternativeLog = scoreValue[observed]!
      let deletionLog = XeusCTC.path(window, []).score
      let margin = expectedLog - max(alternativeLog, deletionLog)

      var tokenSupport: [Double] = []
      var tokenEntropy: [Double] = []
      var best: [Double] = []
      let (_, tracedSpans) = XeusCTC.path(window, chosen, trace: true)
      let spans = tracedSpans ?? []
      let positionCount = min(chosen.count, spans.count)
      for position in 0..<positionCount {
        let token = chosen[position]
        let a = spans[position][0]
        let b = spans[position][1]
        var probabilityRows: [[Double]] = []
        for t in a..<b { probabilityRows.append(window[t].map { exp($0) }) }
        let frameCount = Double(probabilityRows.count)

        var tokenSum = 0.0
        for row in probabilityRows { tokenSum += row[token] }
        best.append(tokenSum / frameCount)

        // equivalents: ids acceptable at `position` while every OTHER position of the sequence
        // still matches `chosen` exactly.
        var equivalents = Set<Int>()
        for seq in al where seq.count == chosen.count {
          var matches = true
          for j in 0..<seq.count where j != position {
            if seq[j] != chosen[j] { matches = false; break }
          }
          if matches { equivalents.insert(seq[position]) }
        }
        let sortedEquivalents = equivalents.sorted()
        var equivalentSum = 0.0
        for row in probabilityRows {
          var rowSum = 0.0
          for id in sortedEquivalents { rowSum += row[id] }
          equivalentSum += rowSum
        }
        tokenSupport.append(min(1.0, equivalentSum / frameCount))

        var entropySum = 0.0
        for (offset, row) in probabilityRows.enumerated() {
          let logRow = window[a + offset]
          var dot = 0.0
          for k in 0..<row.count { dot += row[k] * logRow[k] }
          entropySum += dot
        }
        tokenEntropy.append(-(entropySum / frameCount) / Foundation.log(Double(vocabSize)))
      }

      guard !tokenSupport.isEmpty else { output.append(.alignmentFailure()); continue }
      let support = tokenSupport.min()!
      let confidence = 1.0 / (1.0 + exp(-min(60.0, abs(margin))))
      var status = "uncertain"
      var reason: String? = "ambiguous"

      if support >= thresholds.support, margin >= thresholds.margin, tokenEntropy.max()! < thresholds.entropy {
        status = "correct"; reason = nil
      } else if alternativeLog > max(expectedLog, deletionLog) + thresholds.competitor {
        let competitor = candidateSeq[observed]!
        let (_, otherSpans) = XeusCTC.path(window, competitor, trace: true)
        var strength = 0.0
        if let other = otherSpans, !other.isEmpty {
          var minValue = Double.infinity
          for (t, span) in zip(competitor, other) {
            let a = span[0]
            let b = span[1]
            var sum = 0.0
            for frame in a..<b { sum += exp(window[frame][t]) }
            let mean = sum / Double(b - a)
            if mean < minValue { minValue = mean }
          }
          strength = minValue
        }
        let expectedSymbols = Set(unit.display)
        let confusable = expectedSymbols.contains { sym in XeusInventory.CONFUSION[sym]?.contains(observed) ?? false }
        if strength >= thresholds.strength, confusable {
          status = "likelyIncorrect"; reason = nil
        } else if strength >= thresholds.strength {
          status = "uncertain"; reason = "ambiguousSubstitution"
        }
      }

      output.append(AssessRow(
        status: status, reason: reason,
        start: Double(lo) * step, end: min(duration, Double(hi) * step),
        emissionStart: Double(begin) * step, emissionEnd: min(duration, Double(end) * step),
        windowStart: lo, windowEnd: hi,
        expectedProbability: support, expectedTokenProbability: best.min()!,
        expectedLogLikelihood: expectedLog, alternativeLogLikelihood: alternativeLog,
        deletionLogLikelihood: deletionLog, logMargin: margin,
        closestPhone: observed, confidence: confidence,
        chosen: chosen.map { inverse[$0]! }))
    }
    return output
  }

  // MARK: - expand_rows (evidence.py:305-310)

  static func expandRows(_ units: [XeusInventory.Unit], _ rows: [AssessRow]) -> [PhoneRow] {
    var out: [PhoneRow] = []
    for (unit, row) in zip(units, rows) {
      for phone in unit.display {
        out.append(PhoneRow(row: row, expected: phone, unitID: unit.id, shared: unit.display.count > 1))
      }
    }
    return out
  }

  // MARK: - assess_phones (evidence.py:312-318)

  /// Compatibility wrapper: one unit per phone, no class D, no word-initial position rule.
  static func assessPhones(
    _ lp: [[Double]],
    _ phones: [String],
    _ vocab: [String: Int],
    duration: Double,
    step: Double = 0.02,
    thresholds: Thresholds = .standard
  ) throws -> [PhoneRow] {
    let units = phones.enumerated().map { index, phone in
      XeusInventory.Unit(
        word: "w", indices: [index], display: [phone],
        allowed: XeusInventory.accepted(phone, vocab), cond: [], wordInitial: false)
    }
    let unsupported = zip(phones, units).filter { $0.1.allowed.isEmpty }.map { $0.0 }
    guard unsupported.isEmpty else { throw XeusAssessError.unsupportedTargetPhones(unsupported) }
    let rows = assessUnits(lp, units, units.map { $0.allowed }, vocab, duration: duration, thresholds: thresholds, step: step)
    return expandRows(units, rows)
  }

  // MARK: - coverage (evidence.py:320-326)

  /// Coverage metrics: total phones, scored (correct+likelyIncorrect), and coverage fraction.
  static func coverage(_ rows: [AssessRow]) -> Coverage {
    let total = rows.count
    let correct = rows.filter { $0.status == "correct" }.count
    let incorrect = rows.filter { $0.status == "likelyIncorrect" }.count
    let scored = correct + incorrect
    return Coverage(
      total: total, scored: scored, correct: correct, incorrect: incorrect,
      unassessed: total - scored, coverage: total > 0 ? Double(scored) / Double(total) : 0.0)
  }

  // MARK: - private helpers

  /// Order-preserving de-duplication of token-id sequences — mirrors Python's `_dedupe`
  /// (`dict.fromkeys(tuple(s) for s in seqs)`), duplicated locally since Swift `private` members
  /// aren't visible across files (same pattern as `XeusLattice`'s `dedupeSequences`).
  private static func dedupeSequences(_ sequences: [[Int]]) -> [[Int]] {
    var seen = Set<[Int]>()
    var result: [[Int]] = []
    for sequence in sequences where seen.insert(sequence).inserted { result.append(sequence) }
    return result
  }

  /// Port of `inverse={i:s for s,i in vocab.items()}`. Python's dict comprehension resolves a
  /// same-id collision (two vocab names mapping to the same id) by insertion order — the LAST
  /// name inserted into `vocab` wins. Swift's `[String:Int]` carries no insertion order, so this
  /// picks deterministically instead: prefer whichever name is not the synthetic `"x<id>"`
  /// placeholder that every golden-fixture test vocab (`vocab428`/`dump_golden.py`'s `f'x{i}':i
  /// for i in range(428)` base, later `.update()`-d with a handful of real IPA overrides) fills
  /// every id with before overriding a few — matching Python's "the override always wins" outcome
  /// for that one real convention. A genuine collision between two non-placeholder names (never
  /// produced by any fixture here, since a real production vocab is 1:1) falls back to the
  /// lexicographically smaller name, which is order-independent and therefore still deterministic
  /// — just not meant to imply the smaller name is somehow "more canonical".
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

  /// `max(items, key: score)` with Python's first-occurrence tie-break (only replaces the
  /// running best on a strictly greater score, so an earlier tied item wins).
  private static func argmax<T>(_ items: [T], _ score: (T) -> Double) -> T {
    precondition(!items.isEmpty, "argmax of empty sequence")
    var best = items[0]
    var bestScore = score(best)
    for item in items.dropFirst() {
      let s = score(item)
      if s > bestScore { bestScore = s; best = item }
    }
    return best
  }
}

/// Port of the `ValueError('unsupported target phone(s): ' + ...)` raised by `assess_phones`.
enum XeusAssessError: Error, LocalizedError, Equatable {
  case unsupportedTargetPhones([String])

  var errorDescription: String? {
    switch self {
    case .unsupportedTargetPhones(let phones): return "unsupported target phone(s): \(phones)"
    }
  }
}
