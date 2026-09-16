import Foundation

/// CTC forward-likelihood and Viterbi-trace math — a 1:1 port of
/// `scripts/assessment/phoneticxeus/evidence.py` lines 189-231 (`path`, `realization_likelihood`).
///
/// UK CTC evidence, not calibrated pronunciation accuracy on its own — see `XeusInventory` for the
/// token vocabulary these functions score against, and later tasks for the decision policy built
/// on top of this math.
enum XeusCTC {
  /// Numerically-stable `log(exp(a) + exp(b))`, matching `numpy.logaddexp`: `-inf` combined with
  /// anything finite returns that finite value, and `-inf` combined with `-inf` returns `-inf`
  /// (not `NaN` — the naive `hi + log1p(exp(lo - hi))` formula produces `NaN` when both inputs are
  /// `-inf`, since `-inf - (-inf)` is `NaN`, so that case is special-cased).
  static func logAddExp(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == -Double.infinity, b == -Double.infinity { return -Double.infinity }
    let hi = Swift.max(a, b)
    let lo = Swift.min(a, b)
    return hi + log1p(exp(lo - hi))
  }

  /// Port of `evidence.py`'s `path(lp, labels, trace=False)`.
  ///
  /// `lp` is a `[frames][vocabSize]` matrix of log-probabilities (log-softmax rows). `labels` is
  /// the target token-id sequence (blank excluded); an empty target is the all-blank path. Every
  /// non-empty label must be `>= 4` (ids 0-3 are `<blank>`/reserved) and `< vocabSize` — like
  /// Python's `raise ValueError('special/unmapped target')`, this is an invalid-usage contract
  /// enforced with `precondition`, not a recoverable error: every call site in this port
  /// (`XeusInventory.accepted`/`conditional`-derived token sequences) only ever produces ids in
  /// that range by construction.
  ///
  /// Returns the log-sum CTC forward likelihood (`trace == false`), or — when `trace == true` —
  /// the best (Viterbi) path's score and its recovered per-label emission spans (frame-index
  /// half-open ranges `[start, end)`), or `spans == nil` when no alignment is possible (e.g. a
  /// repeated label with no frame left for the mandatory intervening blank).
  static func path(_ lp: [[Double]], _ labels: [Int], trace: Bool = false) -> (score: Double, spans: [[Int]]?) {
    if labels.isEmpty {
      let blankSum = lp.reduce(0.0) { $0 + $1[0] }
      return (blankSum, trace ? [] : nil)
    }

    let vocabSize = lp.first?.count ?? 0
    precondition(labels.allSatisfy { $0 >= 4 && $0 < vocabSize }, "special/unmapped target")

    // Fast-path rejection mirroring Python's pre-check: a target needs at least one frame per
    // label, plus one extra frame for every adjacent repeated label (the mandatory intervening
    // blank). If there aren't enough frames, no alignment exists at all.
    var repeats = 0
    for i in 1..<labels.count where labels[i] == labels[i - 1] { repeats += 1 }
    if lp.count < labels.count + repeats {
      return (-Double.infinity, nil)
    }

    // `ext` is the standard CTC-expanded label sequence: blank, label0, blank, label1, blank, ...
    let extCount = labels.count * 2 + 1
    var ext = [Int](repeating: 0, count: extCount)
    for i in 0..<labels.count { ext[2 * i + 1] = labels[i] }

    // `skip[2k+1]` is true when label k differs from label k-1: only then can the forward
    // recursion skip over the intervening blank state directly from label (k-1) to label k.
    var skip = [Bool](repeating: false, count: extCount)
    for k in 1..<labels.count where labels[k] != labels[k - 1] { skip[2 * k + 1] = true }

    var prev = [Double](repeating: -Double.infinity, count: extCount)
    prev[0] = 0
    var back: [[UInt8]] = trace ? Array(repeating: [UInt8](repeating: 0, count: extCount), count: lp.count) : []

    for t in 0..<lp.count {
      let row = lp[t]

      var one = [Double](repeating: -Double.infinity, count: extCount)
      for i in 1..<extCount { one[i] = prev[i - 1] }

      var two = [Double](repeating: -Double.infinity, count: extCount)
      for i in 2..<extCount where skip[i] { two[i] = prev[i - 2] }

      var next = [Double](repeating: -Double.infinity, count: extCount)
      if trace {
        var backRow = [UInt8](repeating: 0, count: extCount)
        for i in 0..<extCount {
          // argmax over [stay, one-back, two-back], first-occurrence tie-break — matches
          // `np.stack([prev,one,two]).argmax(0)`.
          var bestIndex = 0
          var bestValue = prev[i]
          if one[i] > bestValue { bestValue = one[i]; bestIndex = 1 }
          if two[i] > bestValue { bestValue = two[i]; bestIndex = 2 }
          backRow[i] = UInt8(bestIndex)
          next[i] = bestValue + row[ext[i]]
        }
        back[t] = backRow
      } else {
        for i in 0..<extCount {
          next[i] = logAddExp(logAddExp(prev[i], one[i]), two[i]) + row[ext[i]]
        }
      }
      prev = next
    }

    if !trace {
      return (logAddExp(prev[extCount - 1], prev[extCount - 2]), nil)
    }

    var state = prev[extCount - 1] > prev[extCount - 2] ? extCount - 1 : extCount - 2
    let score = prev[state]
    if !score.isFinite { return (score, nil) }

    var spans = labels.map { _ in [lp.count, 0] }
    for t in stride(from: lp.count - 1, through: 0, by: -1) {
      if state % 2 == 1 {
        let labelIndex = state / 2
        spans[labelIndex][0] = t
        spans[labelIndex][1] = max(spans[labelIndex][1], t + 1)
      }
      state -= Int(back[t][state])
    }
    return (score, spans)
  }

  /// Port of `evidence.py`'s `realization_likelihood(lp, sequences)`: sum disjoint collapsed CTC
  /// sequences, deduplicated (order-preserving, like Python's `dict.fromkeys`) to avoid double
  /// counting a sequence that appears more than once in `sequences`.
  static func realizationLikelihood(_ lp: [[Double]], _ sequences: [[Int]]) -> Double {
    var seen = Set<[Int]>()
    var unique: [[Int]] = []
    for sequence in sequences where seen.insert(sequence).inserted { unique.append(sequence) }
    guard !unique.isEmpty else { return -Double.infinity }
    return unique.reduce(-Double.infinity) { accumulated, sequence in
      logAddExp(accumulated, path(lp, sequence).score)
    }
  }
}
