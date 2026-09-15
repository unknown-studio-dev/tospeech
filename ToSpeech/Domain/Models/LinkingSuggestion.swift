import Foundation

/// A dictionary-based reading suggestion, never evidence of an acoustic event.
struct LinkingSuggestion: Identifiable, Equatable, Sendable {
  var left: LessonWord
  var right: LessonWord
  var consonant: String
  var vowel: String
  var pronunciation: String
  var id: String { left.id + "→" + right.id }
  var phrase: String { left.text + "‿" + right.text }

  func playbackSpan(in sentence: LessonSentence) -> AudioSpan? {
    guard let a = left.span, let b = right.span,
      a.isValid(duration: sentence.span.end), b.isValid(duration: sentence.span.end),
      a.start >= sentence.span.start, b.start >= a.start, b.end > a.end
    else { return nil }
    return AudioSpan(start: a.start, end: b.end)
  }
}

enum LinkingSuggestions {
  private static let vowels = Set("aeiouyɑɐɒæəɚɛɜɝɞɪɔœøʊʌɨʉɯ")
  private static let consonants = ["tʃ", "dʒ", "p", "b", "t", "d", "k", "ɡ", "g", "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "m", "n", "ŋ", "l", "r", "ɹ"]

  static func suggestions(in sentence: LessonSentence, accent: ReferenceAccent) -> [LinkingSuggestion] {
    zip(sentence.words, sentence.words.dropFirst()).compactMap { left, right in
      guard left.text.last?.isLetter == true, right.text.first?.isLetter == true,
        let a = phonetics(left.ipa(for: accent)), let b = phonetics(right.ipa(for: accent)),
        let initial = b.first, vowels.contains(initial),
        let consonant = consonants.first(where: { a.hasSuffix($0) }),
        let gap = boundary(in: sentence.text, words: sentence.words, leftID: left.id),
        sentence.text[gap].allSatisfy(\.isWhitespace)
      else { return nil }
      return LinkingSuggestion(left: left, right: right, consonant: consonant,
        vowel: String(initial), pronunciation: "/\(displayIPA(left.ipa(for: accent)))‿\(displayIPA(right.ipa(for: accent)))/")
    }
  }

  static func markedTranscript(_ sentence: LessonSentence, suggestions: [LinkingSuggestion]) -> String {
    let ranges = suggestions.compactMap { boundary(in: sentence.text, words: sentence.words, leftID: $0.left.id) }
    var result = sentence.text
    for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
      result.replaceSubrange(range, with: "‿")
    }
    return result
  }

  private static func phonetics(_ value: String?) -> String? {
    guard let value = IPAFormatting.display(value) else { return nil }
    let normalized = value.filter { !"/ˈˌ. ".contains($0) }
    // Alternate/optional pronunciations require a richer parser; don't guess.
    guard !normalized.isEmpty, !normalized.contains(where: { "()[],;|".contains($0) }) else { return nil }
    return normalized
  }

  private static func displayIPA(_ value: String?) -> String {
    String((IPAFormatting.display(value) ?? "//").dropFirst().dropLast())
  }

  private static func boundary(in text: String, words: [LessonWord], leftID: String) -> Range<String.Index>? {
    var cursor = text.startIndex
    var previous: (id: String, end: String.Index)?
    for word in words {
      guard let range = text.range(of: word.text, options: .caseInsensitive, range: cursor..<text.endIndex) else { return nil }
      if let previous, previous.id == leftID { return previous.end..<range.lowerBound }
      previous = (word.id, range.upperBound)
      cursor = range.upperBound
    }
    return nil
  }
}
