import Foundation

/// Uncommitted field text belongs to the editor so Preview and Save see the same
/// values even while a field still has keyboard focus. Nil preserves full precision
/// for an untouched boundary rather than reparsing its two-decimal display.
struct TimingNumericInput {
  var start: String?
  var end: String?
  var lastEditedStart = true
  var movesRange = false
  var isDirty: Bool { start != nil || end != nil }

  mutating func edit(_ text: String, isStart: Bool) {
    if isStart { start = text } else { end = text }
    lastEditedStart = isStart
  }

  func resolve(span: AudioSpan, bounds: AudioSpan, moving: Bool, locale: Locale = .current)
    -> AudioSpan?
  {
    func parse(_ text: String?, fallback: Double) -> Double? {
      guard let text else { return fallback }
      let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: "."))
      return value.flatMap { $0.isFinite ? $0 : nil }
    }
    guard let start = parse(start, fallback: span.start),
      let end = parse(end, fallback: span.end) else { return nil }
    let result: AudioSpan
    if moving && isDirty {
      guard let moved = TimingRules.moved(span, matchingStart: lastEditedStart,
        to: lastEditedStart ? start : end, limits: bounds) else { return nil }
      result = moved
    } else {
      result = AudioSpan(start: start, end: end)
    }
    guard result.start.isFinite, result.end.isFinite,
      result.start >= bounds.start, result.end <= bounds.end,
      result.duration > TimingRules.minimumSpan else { return nil }
    return result
  }
}

enum TimingInputTarget: Hashable, Sendable {
  case sentence
  case word(String)
}

struct TimingInputFailure: Error {
  let target: TimingInputTarget
  let message: String
}

/// Raw fields are kept per target, including invalid text. Navigation never needs
/// to validate them; saving resolves every target into a temporary sentence first.
struct TimingInputDrafts {
  private var inputs: [TimingInputTarget: TimingNumericInput] = [:]

  subscript(target: TimingInputTarget) -> TimingNumericInput {
    get { inputs[target] ?? TimingNumericInput() }
    set { inputs[target] = newValue.isDirty ? newValue : nil }
  }

  var isDirty: Bool { !inputs.isEmpty }

  mutating func retainWords(_ ids: Set<String>) {
    inputs = inputs.filter { target, _ in
      if case .word(let id) = target { return ids.contains(id) }
      return true
    }
  }

  func applying(to sentence: LessonSentence, duration: Double, locale: Locale)
    -> Result<LessonSentence, TimingInputFailure>
  {
    var result = sentence
    let invalidRange = "Start must be before end and inside the available audio."
    if let input = inputs[.sentence] {
      guard let span = input.resolve(span: result.span,
        bounds: AudioSpan(start: 0, end: duration), moving: input.movesRange, locale: locale)
      else { return .failure(TimingInputFailure(target: .sentence, message: invalidRange)) }
      if input.movesRange {
        guard let shifted = TimingRules.shifted(result, by: span.start - result.span.start, duration: duration)
        else { return .failure(TimingInputFailure(target: .sentence, message: invalidRange)) }
        result = shifted
      } else { result.span = span }
    }
    for index in result.words.indices {
      let target = TimingInputTarget.word(result.words[index].id)
      guard let input = inputs[target] else { continue }
      if result.words[index].span == nil && (input.start == nil || input.end == nil) {
        return .failure(TimingInputFailure(target: target, message: "Enter numeric start and end times."))
      }
      // Resolve all edits before checking neighbors, so two adjacent corrections
      // can be saved together even if either would overlap the old boundary.
      guard let span = input.resolve(span: result.words[index].span ?? result.span,
        bounds: result.span, moving: input.movesRange && result.words[index].span != nil, locale: locale)
      else { return .failure(TimingInputFailure(target: target, message: invalidRange)) }
      result.words[index].span = span
      result.words[index].needsTimingReview = false
    }
    guard result.span.isValid(duration: duration) else {
      return .failure(TimingInputFailure(target: .sentence,
        message: "Sentence timing must stay inside the source audio."))
    }
    var previousEnd = result.span.start
    for word in result.words {
      guard let span = word.span else { continue }
      let target = TimingInputTarget.word(word.id)
      guard span.isValid(duration: duration),
        span.start >= result.span.start, span.end <= result.span.end else {
        return .failure(TimingInputFailure(target: target, message: invalidRange))
      }
      guard span.start >= previousEnd else {
        return .failure(TimingInputFailure(target: target, message: "Word timings cannot overlap."))
      }
      previousEnd = span.end
    }
    if let message = TimingRules.validate(result, duration: duration) {
      return .failure(TimingInputFailure(target: .sentence, message: message))
    }
    return .success(result)
  }
}

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
