import Foundation

/// Pure CTC Viterbi alignment. Blank and repeated-character states are explicit;
/// an impossible path is rejected instead of distributing words across the clip.
enum CTCAlignment {
  struct Span: Equatable, Sendable {
    let start: Int
    let end: Int
  }

  static func align(logProbabilities: [[Float]], labels: [Int], blank: Int = 0) throws -> [Span]? {
    guard !labels.isEmpty, !logProbabilities.isEmpty,
      let width = logProbabilities.first?.count, width > blank,
      labels.allSatisfy({ $0 >= 0 && $0 < width && $0 != blank }),
      logProbabilities.allSatisfy({ $0.count == width && $0.allSatisfy(\.isFinite) }),
      labels.count <= 1024, logProbabilities.count <= 1600
    else { return nil }
    let states = labels.count * 2 + 1
    let frames = logProbabilities.count
    guard frames >= labels.count + zip(labels, labels.dropFirst()).filter({ $0 == $1 }).count else { return nil }
    var previous = Array(repeating: -Float.infinity, count: states)
    previous[0] = 0
    var trace = Array(repeating: UInt8(0), count: states * frames)
    for t in 0..<frames {
      if t % 32 == 0 { try Task.checkCancellation() }
      var current = Array(repeating: -Float.infinity, count: states)
      for s in 0..<states {
        let label = s % 2 == 0 ? blank : labels[s / 2]
        var score = previous[s]
        var step: UInt8 = 0
        if s > 0, previous[s - 1] > score { score = previous[s - 1]; step = 1 }
        if s > 1, s % 2 == 1, labels[s / 2] != labels[s / 2 - 1], previous[s - 2] > score {
          score = previous[s - 2]; step = 2
        }
        current[s] = score + logProbabilities[t][label]
        trace[t * states + s] = step
      }
      previous = current
    }
    var s = previous[states - 1] > previous[states - 2] ? states - 1 : states - 2
    guard previous[s].isFinite else { return nil }
    var starts = Array(repeating: frames, count: labels.count)
    var ends = Array(repeating: 0, count: labels.count)
    for t in (0..<frames).reversed() {
      if s % 2 == 1 {
        starts[s / 2] = t
        ends[s / 2] = max(ends[s / 2], t + 1)
      }
      s -= Int(trace[t * states + s])
    }
    guard zip(starts, ends).allSatisfy({ $0 < $1 }) else { return nil }
    return zip(starts, ends).map { Span(start: $0, end: $1) }
  }
}
