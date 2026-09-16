import Foundation

/// Global Viterbi CTC lattice over dictionary variants and phone realizations — a 1:1 port of
/// `scripts/assessment/phoneticxeus/evidence.py` lines 96-165 (`align_variants`), 194-199
/// (`align_units`) and 201-205 (`validate`).
///
/// This is the hardest and most index-sensitive port in the XEUS native effort: the predecessor
/// graph (`labels`/`owners`/`parents`), the frame-by-frame Viterbi over that graph
/// (`prev[predecessors].argmax`), the backtrace to per-phone emission anchors and the per-word
/// variant selection are all translated structurally, index-for-index, from the numpy original.
///
/// UK CTC evidence, not calibrated pronunciation accuracy on its own — consumes `XeusInventory`'s
/// `Unit`/`accepted` token sequences and `XeusCTC` conventions; see later tasks for the decision
/// policy built on top.
enum XeusLattice {
  /// Hashable substitute for Python's `(wi, vi, pi)` owner tuple used as an `anchors` dict key.
  private struct Owner: Hashable {
    let wi: Int
    let vi: Int
    let pi: Int
  }

  /// Order-preserving de-duplication of token ids — mirrors Python's `dict.fromkeys(incoming)`.
  private static func dedupeInts(_ values: [Int]) -> [Int] {
    var seen = Set<Int>()
    var result: [Int] = []
    for value in values where seen.insert(value).inserted { result.append(value) }
    return result
  }

  /// Order-preserving de-duplication of token-id sequences — mirrors Python's `_dedupe`
  /// (`dict.fromkeys(tuple(s) for s in seqs)`).
  private static func dedupeSequences(_ sequences: [[Int]]) -> [[Int]] {
    var seen = Set<[Int]>()
    var result: [[Int]] = []
    for sequence in sequences where seen.insert(sequence).inserted { result.append(sequence) }
    return result
  }

  /// Port of `evidence.py`'s `validate(lp)`. The shape/range/normalization contract of a CTC
  /// log-probability matrix is invalid usage (not a recoverable error) — like `XeusCTC.path`'s
  /// `special/unmapped target` check, it is enforced with `precondition`, mirroring the Python
  /// `raise ValueError`.
  private static func validate(_ lp: [[Double]]) {
    let frames = lp.count
    precondition(1 <= frames && frames <= 1600, "invalid CTC log_probs shape/range: frames=\(frames)")
    for row in lp {
      precondition(row.count == 428, "invalid CTC log_probs shape/range: width=\(row.count)")
      precondition(row.allSatisfy { $0.isFinite }, "invalid CTC log_probs shape/range: non-finite")
      let sum = row.reduce(0.0) { $0 + Foundation.exp($1) }
      precondition(abs(sum - 1) <= 2e-4, "CTC rows must be log_softmax probabilities")
    }
  }

  /// Port of `evidence.py`'s `align_variants(lp, words, vocab, options=None)`.
  ///
  /// `options(wi, vi, pi)` returns the token sequences allowed at that lattice position; unlike the
  /// Python default (`alignment_options(phone, vocab)`), the native port has no vocab and always
  /// requires the closure — every call site supplies it. The inner `Int` values of `words` are
  /// per-phone placeholders: only the phone count per variant matters (the emission owners are
  /// `(wi, vi, pi)`, and the token ids come from `options`), exactly as Python's `phone` value is
  /// unused once a custom `options` localizer is given.
  ///
  /// A path chooses exactly one whole variant per word (it cannot splice halves of different
  /// variants); repeated labels require a blank, including at branch boundaries; every emitted
  /// label retains its word/variant/phone identity. Returns selected variant indices and
  /// independent phone emission anchors (half-open frame spans `[start, end)`), or `nil` when no
  /// alignment is possible.
  static func alignVariants(
    _ lp: [[Double]],
    _ words: [[[Int]]],
    options: ((Int, Int, Int) -> [[Int]])?
  ) -> (selected: [Int], spans: [[[Int]]])? {
    guard let opts = options else {
      preconditionFailure("alignVariants requires an options closure (no default vocab localization in the native port)")
    }
    validate(lp)
    precondition(!words.isEmpty && words.count <= 128, "invalid target word count")

    // --- Predecessor lattice: labels[i] token, owners[i] emitting phone (or nil for blank), ---
    // --- parents[i] the incoming node indices. Node 0 is the initial blank state.            ---
    var labels: [Int] = [0]
    var owners: [Owner?] = [nil]
    var parents: [[Int]] = [[0]]
    var previous: [Int] = [0]

    for (wi, variants) in words.enumerated() {
      precondition(!variants.isEmpty && variants.count <= 64, "invalid variant count")
      var wordEnds: [Int] = []
      for (vi, phones) in variants.enumerated() {
        precondition(!phones.isEmpty && phones.count <= 1024, "invalid variant phone count")
        var ends = previous
        for pi in 0..<phones.count {
          let choices = opts(wi, vi, pi)
          precondition(!choices.isEmpty, "unsupported target phone")
          var nextEnds: [Int] = []
          for sequence in choices {
            var predecessors = ends
            for token in sequence {
              let node = labels.count
              // A label state followed by its blank state. `ends` contains preceding label
              // states, except the initial blank 0.
              var incoming = [node]
              for pred in predecessors {
                incoming.append(pred == 0 ? 0 : pred + 1)
                if pred != 0 && labels[pred] != token { incoming.append(pred) }
              }
              labels.append(token); labels.append(0)
              owners.append(Owner(wi: wi, vi: vi, pi: pi)); owners.append(nil)
              parents.append(dedupeInts(incoming)); parents.append([node, node + 1])
              predecessors = [node]
            }
            nextEnds.append(contentsOf: predecessors)
          }
          ends = nextEnds
        }
        wordEnds.append(contentsOf: ends)
      }
      previous = wordEnds
    }

    // Bound graph/backtrace memory for untrusted long targets.
    let n = labels.count
    precondition(n <= 24000, "target lattice too large")
    let width = parents.map { $0.count }.max()!
    precondition(width <= 2048, "target lattice too wide")

    // `predecessors[i]` is padded to `width` with the sentinel index `n`, which indexes the always
    // `-inf` extra slot of `prev` — mirrors numpy's `np.full((len(labels),width),len(labels))`.
    let sentinel = n
    var predecessors = [[Int]](repeating: [Int](repeating: sentinel, count: width), count: n)
    for i in 0..<n {
      let incoming = parents[i]
      for j in 0..<incoming.count { predecessors[i][j] = incoming[j] }
    }

    // `prev` has `n+1` entries; index `n` (the sentinel slot) stays `-inf` for every frame.
    var prev = [Double](repeating: -Double.infinity, count: n + 1)
    prev[0] = 0
    var back = [[Int]](repeating: [Int](repeating: 0, count: n), count: lp.count)

    for t in 0..<lp.count {
      let row = lp[t]
      var next = [Double](repeating: -Double.infinity, count: n + 1)
      for i in 0..<n {
        // `scores = prev[predecessors]; choice = scores.argmax(1)` — argmax with numpy's
        // first-occurrence tie-break (replace only on a strictly greater score).
        var bestJ = 0
        var bestValue = prev[predecessors[i][0]]
        for j in 1..<width {
          let score = prev[predecessors[i][j]]
          if score > bestValue { bestValue = score; bestJ = j }
        }
        back[t][i] = predecessors[i][bestJ]
        next[i] = bestValue + row[labels[i]]
      }
      prev = next
    }

    // `finals` are, for each ending label node, that node and its trailing blank; pick the highest
    // scoring, with `max`'s first-occurrence tie-break (replace only on strictly greater).
    var finals: [Int] = []
    for node in previous { finals.append(node); finals.append(node + 1) }
    var state = finals[0]
    var stateValue = prev[finals[0]]
    for i in finals.dropFirst() where prev[i] > stateValue { stateValue = prev[i]; state = i }
    if !prev[state].isFinite { return nil }

    // Backtrace to per-phone emission anchors: `anchors[owner]` becomes `[minFrame, maxFrame+1]`.
    var anchors: [Owner: [Int]] = [:]
    for t in stride(from: lp.count - 1, through: 0, by: -1) {
      if let owner = owners[state] {
        if anchors[owner] == nil { anchors[owner] = [t, t + 1] }
        anchors[owner]![0] = t
      }
      state = back[t][state]
    }

    // Per-word variant selection: every anchored phone of a word must belong to a single variant.
    var selected: [Int] = []
    var spans: [[[Int]]] = []
    for (wi, variants) in words.enumerated() {
      var choices = Set<Int>()
      for (owner, _) in anchors where owner.wi == wi { choices.insert(owner.vi) }
      precondition(choices.count == 1, "invalid variant backtrace")
      let vi = choices.first!
      selected.append(vi)
      var wordSpans: [[Int]] = []
      for pi in 0..<variants[vi].count { wordSpans.append(anchors[Owner(wi: wi, vi: vi, pi: pi)]!) }
      spans.append(wordSpans)
    }
    return (selected, spans)
  }

  /// Port of `evidence.py`'s `align_units(lp, units, extra=None)`. Linear-chain alignment of units
  /// as a single pseudo-word of all units; each unit position localizes with `allowed ∪ extra`
  /// (licensed class-D sequences). Returns the per-unit emission spans, or `nil` when no alignment
  /// is possible.
  static func alignUnits(_ lp: [[Double]], _ units: [XeusInventory.Unit], extra: [[[Int]]]?) -> [[Int]]? {
    // Python's `extra = extra or [[] for _ in units]` treats `None` and an empty list alike.
    let extraSequences: [[[Int]]]
    if let extra = extra, !extra.isEmpty { extraSequences = extra }
    else { extraSequences = Array(repeating: [], count: units.count) }

    let opts: [[[Int]]] = zip(units, extraSequences).map { unit, e in dedupeSequences(unit.allowed + e) }
    // A single pseudo-word / single variant whose phones are `list(range(len(units)))`
    // placeholders; the options closure keys on the unit position `pi`.
    let placeholder = Array(0..<units.count)
    let words: [[[Int]]] = [[placeholder]]
    let result = alignVariants(lp, words, options: { _, _, pi in opts[pi] })
    return result.map { $0.spans[0] }
  }
}
