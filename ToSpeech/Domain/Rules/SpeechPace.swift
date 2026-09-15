import Foundation

/// The reference speaker's rhythm, read off the lesson's word timing: how fast
/// each word is spoken (syllables per second against the lesson's median) and
/// where the speaker pauses. It describes the original audio only and never
/// judges the learner; words whose timing is unreliable are left unmarked.
enum SpeechPace {
  /// Silences shorter than this are articulation gaps, not pauses (the same
  /// threshold the delivery review uses).
  static let pauseThreshold = 0.18
  /// Deviation (log2 of rate ÷ baseline) inside this band reads as even pace.
  static let evenBand = 0.5
  /// Word timing below this length is alignment noise rather than a rate.
  static let minimumDuration = 0.04

  enum Level: Equatable, Sendable { case slow, even, fast }

  struct Word: Identifiable, Equatable, Sendable {
    var id: String
    var syllables: Int
    var syllablesPerSecond: Double
    /// log2(rate ÷ baseline), clamped to ±1 so double/half speed saturates.
    var deviation: Double
    var level: Level {
      deviation > SpeechPace.evenBand ? .fast : deviation < -SpeechPace.evenBand ? .slow : .even
    }
    /// 0 at the edge of the even band, 1 at double or half the baseline rate.
    var intensity: Double {
      max(0, min(1, (abs(deviation) - SpeechPace.evenBand) / (1 - SpeechPace.evenBand)))
    }
  }

  struct Pause: Identifiable, Equatable, Sendable {
    var afterWordID: String
    var duration: Double
    var id: String { afterWordID }
  }

  struct Analysis: Equatable, Sendable {
    var words: [String: Word] = [:]
    var pauses: [Pause] = []
    var isEmpty: Bool { words.isEmpty && pauses.isEmpty }
    func pause(after wordID: String) -> Pause? { pauses.first { $0.afterWordID == wordID } }
  }

  /// Median syllable rate over every reliably timed word; `nil` when fewer than
  /// four words qualify, which is too little to call anything fast or slow.
  static func baseline(in sentences: [LessonSentence], accent: ReferenceAccent) -> Double? {
    let rates = sentences.flatMap { sentence in
      sentence.words.compactMap { rate(of: $0, in: sentence, accent: accent) }
    }.sorted()
    guard rates.count >= 4 else { return nil }
    let middle = rates.count / 2
    return rates.count.isMultiple(of: 2) ? (rates[middle - 1] + rates[middle]) / 2 : rates[middle]
  }

  static func analyze(_ sentence: LessonSentence, accent: ReferenceAccent, baseline: Double?) -> Analysis {
    var analysis = Analysis()
    if let baseline, baseline > 0 {
      for word in sentence.words {
        guard let rate = rate(of: word, in: sentence, accent: accent) else { continue }
        analysis.words[word.id] = Word(
          id: word.id, syllables: syllableCount(of: word, accent: accent), syllablesPerSecond: rate,
          deviation: min(1, max(-1, log2(rate / baseline))))
      }
    }
    for (left, right) in zip(sentence.words, sentence.words.dropFirst()) {
      guard let a = reliableSpan(left, in: sentence), let b = reliableSpan(right, in: sentence) else { continue }
      let gap = b.start - a.end
      if gap >= pauseThreshold { analysis.pauses.append(Pause(afterWordID: left.id, duration: gap)) }
    }
    return analysis
  }

  // MARK: - Timing

  private static func reliableSpan(_ word: LessonWord, in sentence: LessonSentence) -> AudioSpan? {
    guard !word.needsTimingReview, IPAFormatting.isPronounceable(word.text), let span = word.span,
      span.isValid(duration: sentence.span.end), span.start >= sentence.span.start
    else { return nil }
    return span
  }

  private static func rate(of word: LessonWord, in sentence: LessonSentence, accent: ReferenceAccent) -> Double? {
    guard let span = reliableSpan(word, in: sentence), span.duration >= minimumDuration else { return nil }
    return Double(syllableCount(of: word, accent: accent)) / span.duration
  }

  // MARK: - Syllables

  static func syllableCount(of word: LessonWord, accent: ReferenceAccent) -> Int {
    if let ipa = word.resolvedIPA(for: accent)?.text, let count = syllableCount(ipa: ipa) { return count }
    return syllableCount(spelling: word.text)
  }

  private static let diphthongs: Set<String> = [
    "eɪ", "aɪ", "ɔɪ", "əʊ", "oʊ", "aʊ", "ɪə", "eə", "ɛə", "ʊə",
    "ʌɪ", "ɑɪ", "ɑʊ", "æɪ", "æʊ", "ɛɪ", "ɔʊ",
  ]
  private static let vowels = Set("iɪeɛæaɑɒɔoʊuʌɐɜəɚɝœøɨʉɯyɵ".unicodeScalars)
  private static let syllabicMark: Unicode.Scalar = "\u{0329}"

  /// Counts vowel nuclei (diphthongs count once, syllabic consonants count) in
  /// the first listed pronunciation, ignoring optional `(ə)` segments. `nil`
  /// when the notation carries no nucleus at all.
  static func syllableCount(ipa: String) -> Int? {
    guard let shown = IPAFormatting.display(ipa) else { return nil }
    var text = ""
    var skipping = false
    for character in shown.prefix(while: { !",;|".contains($0) }) {
      switch character {
      case "(": skipping = true
      case ")": skipping = false
      default: if !skipping { text.append(character) }
      }
    }
    let characters = Array(text)
    var count = 0
    var index = 0
    while index < characters.count {
      let scalars = characters[index].unicodeScalars
      guard let base = scalars.first else { index += 1; continue }
      if scalars.contains(syllabicMark) {
        count += 1
        index += 1
      } else if vowels.contains(base) {
        count += 1
        if index + 1 < characters.count, let next = characters[index + 1].unicodeScalars.first,
          diphthongs.contains(String(base) + String(next)) {
          index += 2
        } else {
          index += 1
        }
      } else {
        index += 1
      }
    }
    return count > 0 ? count : nil
  }

  /// A rough spelling-based count for words without any pronunciation.
  static func syllableCount(spelling text: String) -> Int {
    let letters = text.lowercased().filter(\.isLetter)
    guard !letters.isEmpty else { return 1 }
    let vowels = Set("aeiouy")
    var groups = 0
    var previousVowel = false
    for character in letters {
      let vowel = vowels.contains(character)
      if vowel && !previousVowel { groups += 1 }
      previousVowel = vowel
    }
    if groups > 1, letters.count > 2, letters.hasSuffix("e"), !letters.hasSuffix("le"), !letters.hasSuffix("ee") {
      groups -= 1
    }
    if groups > 1, letters.hasSuffix("ed"), let before = letters.dropLast(2).last, !"td".contains(before) {
      groups -= 1
    }
    return max(1, groups)
  }
}
