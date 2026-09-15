import Foundation

/// A reference (caption) word carrying the audio time range of its aligned
/// ASR word, or `nil` timing when the ASR transcript had no counterpart.
struct AlignedWord: Equatable, Sendable {
  let text: String
  let start: TimeInterval?
  let end: TimeInterval?
  let isMatched: Bool
  var candidateText: String? = nil
}

/// Aligns clean reference text (YouTube caption words) onto accurate ASR word
/// timings using Needleman-Wunsch global alignment. Reference text is kept;
/// timing is borrowed from the matched ASR word. Pure logic, fully testable.
enum TranscriptAligner {
  static func align(reference: [String], timed: [TimedWord]) -> [AlignedWord] {
    let m = reference.count
    guard m > 0 else { return [] }
    let n = timed.count
    let refNorm = reference.map(normalize)
    let timedNorm = timed.map { normalize($0.text) }

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m { dp[i][0] = -i }
    if n > 0 {
      for j in 1...n { dp[0][j] = -j }
      for i in 1...m {
        for j in 1...n {
          let score = refNorm[i - 1] == timedNorm[j - 1] ? 2 : -1
          dp[i][j] = max(dp[i - 1][j - 1] + score, dp[i - 1][j] - 1, dp[i][j - 1] - 1)
        }
      }
    }

    var i = m
    var j = n
    var out: [AlignedWord] = []
    while i > 0 {
      if j > 0 {
        let score = refNorm[i - 1] == timedNorm[j - 1] ? 2 : -1
        if dp[i][j] == dp[i - 1][j - 1] + score {
          let matched = refNorm[i - 1] == timedNorm[j - 1]
          out.append(
            AlignedWord(
              text: reference[i - 1], start: timed[j - 1].start, end: timed[j - 1].end,
              isMatched: matched, candidateText: timed[j - 1].text))
          i -= 1
          j -= 1
          continue
        }
        if dp[i][j] == dp[i][j - 1] - 1 {
          // Deletion: ASR has an extra word. Consume it, emit nothing.
          j -= 1
          continue
        }
      }
      // Insertion: reference word with no ASR counterpart.
      out.append(AlignedWord(text: reference[i - 1], start: nil, end: nil, isMatched: false))
      i -= 1
    }
    return out.reversed()
  }

  private static func normalize(_ token: String) -> String {
    token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
  }
}
