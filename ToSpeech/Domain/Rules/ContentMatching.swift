import Foundation

/// Text evidence from ASR, never a pronunciation grade. Preserve edit order,
/// including repeated words, instead of comparing unordered word sets.
struct ContentMatch: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case matched, missing, extra, different }
  struct Word: Codable, Equatable, Sendable {
    let kind: Kind
    let expected: String?
    let observed: String?
  }
  let words: [Word]
  var differences: [Word] { words.filter { $0.kind != .matched } }
  var hasRecognizedSpeech: Bool { words.contains { $0.observed != nil } }

  static func tokens(_ text: String) -> [String] {
    let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
    return normalized.split { !$0.isLetter && !$0.isNumber && $0 != "'" }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
      .filter { !$0.isEmpty }
  }

  static func compare(expected: String, observed: String) throws -> ContentMatch {
    let a = tokens(expected), b = tokens(observed)
    // Bound the matrix for corrupted targets or hallucinated model output.
    guard a.count <= 512, b.count <= 512 else { throw ContentMatchingError.tooLong }
    // Prefer the path preserving the most exact words when edit counts tie.
    // One edit outweighs every possible match in these bounded sequences.
    let editCost = 1_024
    var cost = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { cost[i][0] = i * editCost }
    for j in 0...b.count { cost[0][j] = j * editCost }
    if !a.isEmpty && !b.isEmpty {
      for i in 1...a.count {
        for j in 1...b.count {
          cost[i][j] = min(cost[i - 1][j] + editCost, cost[i][j - 1] + editCost,
            cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? -1 : editCost))
        }
      }
    }
    var i = a.count, j = b.count
    var words: [Word] = []
    while i > 0 || j > 0 {
      if i > 0 && j > 0 && a[i - 1] == b[j - 1] && cost[i][j] == cost[i - 1][j - 1] - 1 {
        words.append(Word(kind: .matched, expected: a[i - 1], observed: b[j - 1]))
        i -= 1; j -= 1
      } else if i > 0 && j > 0 && cost[i][j] == cost[i - 1][j - 1] + editCost {
        words.append(Word(kind: .different, expected: a[i - 1], observed: b[j - 1]))
        i -= 1; j -= 1
      } else if i > 0 && cost[i][j] == cost[i - 1][j] + editCost {
        words.append(Word(kind: .missing, expected: a[i - 1], observed: nil)); i -= 1
      } else {
        words.append(Word(kind: .extra, expected: nil, observed: b[j - 1])); j -= 1
      }
    }
    return ContentMatch(words: words.reversed())
  }
}

enum ContentMatchingError: Error { case tooLong }
