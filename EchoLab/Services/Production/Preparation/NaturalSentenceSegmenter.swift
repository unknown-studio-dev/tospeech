import Foundation
import NaturalLanguage

/// A word with an audio time range, as produced by an ASR engine.
struct TimedWord: Codable, Equatable, Sendable {
  let text: String
  let start: TimeInterval
  let end: TimeInterval
}

/// Tunables for how spoken audio is cut into natural sentences.
struct SentenceSegmentationOptions: Equatable, Sendable {
  /// Optional pause splitting for explicit callers. Normal lesson import uses sentences.
  var pauseThreshold: TimeInterval
  /// Segments shorter than this are merged into a neighbour.
  var minDuration: TimeInterval

  init(pauseThreshold: TimeInterval = .infinity, minDuration: TimeInterval = 0) {
    self.pauseThreshold = pauseThreshold
    self.minDuration = minDuration
  }

  static let `default` = SentenceSegmentationOptions()
}

/// Sentence boundaries come from the recognized text, including abbreviation handling.
/// Default import never splits a grammatical sentence at a reading pause or duration cap.
enum NaturalSentenceSegmenter {
  static func segment(
    _ words: [TimedWord], options: SentenceSegmentationOptions = .default
  ) -> [CaptionCue] {
    guard !words.isEmpty else { return [] }
    let normalized = words.compactMap { word -> TimedWord? in
      let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return TimedWord(text: text, start: word.start, end: word.end)
    }
    let primary = primaryGroups(normalized, pauseThreshold: options.pauseThreshold)
    let merged = mergeShort(primary, minDuration: options.minDuration)
    return merged.map(cue(from:))
  }

  /// Respect text sentence boundaries; pause splitting is opt-in.
  private static func primaryGroups(
    _ words: [TimedWord], pauseThreshold: TimeInterval
  ) -> [[TimedWord]] {
    var fullText = ""
    var offsets: [Int] = []
    for word in words {
      fullText = TranscriptText.appending(word.text, to: fullText)
      offsets.append(fullText.utf16.count)
    }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.setLanguage(.english)
    tokenizer.string = fullText
    var sentenceEnds: Set<Int> = []
    tokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { range, _ in
      let end = NSRange(range, in: fullText).upperBound
      if let index = offsets.lastIndex(where: { $0 <= end }) { sentenceEnds.insert(index) }
      return true
    }
    var groups: [[TimedWord]] = []
    var current: [TimedWord] = []
    for index in words.indices {
      current.append(words[index])
      let isLast = index == words.count - 1
      let gapAfter = isLast ? .infinity : words[index + 1].start - words[index].end
      if isLast || sentenceEnds.contains(index) || gapAfter > pauseThreshold {
        groups.append(current)
        current = []
      }
    }
    if !current.isEmpty { groups.append(current) }
    return groups
  }

  /// Pass 2: fold groups forward until each reaches the minimum duration. This
  /// only rescues fragments too short to stand alone; it never splits, so a
  /// long sentence is left whole.
  private static func mergeShort(
    _ groups: [[TimedWord]], minDuration: TimeInterval
  ) -> [[TimedWord]] {
    guard let first = groups.first else { return [] }
    var merged: [[TimedWord]] = []
    var buffer = first
    for group in groups.dropFirst() {
      if duration(buffer) < minDuration {
        buffer.append(contentsOf: group)
      } else {
        merged.append(buffer)
        buffer = group
      }
    }
    merged.append(buffer)
    if merged.count > 1, duration(merged[merged.count - 1]) < minDuration {
      let tail = merged.removeLast()
      merged[merged.count - 1].append(contentsOf: tail)
    }
    return merged
  }

  private static func cue(from group: [TimedWord]) -> CaptionCue {
    CaptionCue(
      start: group.first?.start ?? 0,
      end: group.last?.end ?? 0,
      text: TranscriptText.join(group.map(\.text)),
      words: group.map { CaptionWord(text: $0.text, start: $0.start, end: $0.end) })
  }

  private static func duration(_ group: [TimedWord]) -> TimeInterval {
    guard let first = group.first, let last = group.last else { return 0 }
    return last.end - first.start
  }

 }

/// Normalize ASR token spacing without adding spaces before punctuation or contractions.
enum TranscriptText {
  static func join(_ tokens: [String]) -> String {
    tokens.reduce("") { appending($1, to: $0) }
  }

  static func appending(_ token: String, to text: String) -> String {
    let token = token.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !token.isEmpty else { return text }
    guard !text.isEmpty else { return token }
    let attaches = token.first.map { ",.!?;:%)]}…".contains($0) } ?? false
    let contraction = ["'s", "'t", "'re", "'ve", "'ll", "'d", "'m", "n't", "’s", "’re", "’ve", "’ll", "’d", "’m", "n’t"].contains(token.lowercased())
    let followsOpening = text.last.map { "([{“".contains($0) } ?? false
    return text + (attaches || contraction || followsOpening ? "" : " ") + token
  }
}
