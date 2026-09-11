import Foundation

enum TimingRules {
  static let minimumSpan = 0.01

  static func validate(_ sentence: LessonSentence, duration: Double) -> String? {
    guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "English transcript is required."
    }
    guard sentence.span.isValid(duration: duration) else {
      return "Sentence timing must stay inside the source audio."
    }

    var previousEnd = sentence.span.start
    for word in sentence.words {
      guard let span = word.span else { continue }
      guard span.isValid(duration: duration),
        span.start >= sentence.span.start,
        span.end <= sentence.span.end
      else {
        return "Timing for \(word.text) must stay inside the sentence."
      }
      guard span.start >= previousEnd else {
        return "Word timings cannot overlap."
      }
      previousEnd = span.end
    }
    return nil
  }

  static func reconcile(text: String, sentenceID: String, candidates: [LessonWord]) -> [LessonWord]
  {
    let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var unused = Set(candidates.indices)
    var reservedIDs = Set(candidates.map(\.id))

    var reconciled = tokens.enumerated().map { tokenIndex, token in
      let normalized = normalize(token)
      let match = unused.sorted().first { normalize(candidates[$0].text) == normalized }
      if let match {
        unused.remove(match)
        var word = candidates[match]
        word.text = token
        if word.span == nil || word.span?.duration ?? 0 <= minimumSpan {
          word.needsTimingReview = true
        }
        return word
      }

      let stem = "\(sentenceID)-edited-word-\(tokenIndex)"
      var id = stem
      var suffix = 2
      while reservedIDs.contains(id) {
        id = "\(stem)-\(suffix)"
        suffix += 1
      }
      reservedIDs.insert(id)
      return LessonWord(
        id: id, text: token, ipaUK: nil, ipaUS: nil, span: nil, needsTimingReview: true)
    }
    var previousEnd = -Double.infinity
    for index in reconciled.indices {
      guard let span = reconciled[index].span else { continue }
      if span.start < previousEnd {
        reconciled[index].span = nil
        reconciled[index].needsTimingReview = true
      } else {
        previousEnd = span.end
      }
    }
    return reconciled
  }

  static func shifted(_ sentence: LessonSentence, by delta: Double, duration: Double)
    -> LessonSentence?
  {
    var copy = sentence
    let shiftedSpan = AudioSpan(start: sentence.span.start + delta, end: sentence.span.end + delta)
    guard shiftedSpan.isValid(duration: duration) else { return nil }
    copy.span = shiftedSpan
    copy.words = sentence.words.map { word in
      var shiftedWord = word
      if let span = word.span {
        shiftedWord.span = AudioSpan(start: span.start + delta, end: span.end + delta)
      }
      return shiftedWord
    }
    return copy
  }

  static func viewport(around span: AudioSpan, duration: Double, padding: Double = 2) -> AudioSpan {
    let safeDuration = max(duration, minimumSpan)
    let start = max(0, span.start - padding)
    let end = min(safeDuration, span.end + padding)
    return AudioSpan(start: start, end: max(end, min(safeDuration, start + minimumSpan)))
  }

  static func moved(_ span: AudioSpan, matchingStart: Bool, to value: Double, limits: AudioSpan)
    -> AudioSpan?
  {
    let delta = value - (matchingStart ? span.start : span.end)
    let result = AudioSpan(start: span.start + delta, end: span.end + delta)
    guard result.start >= limits.start, result.end <= limits.end else { return nil }
    return result
  }

  private static func normalize(_ token: String) -> String {
    token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
  }
}
