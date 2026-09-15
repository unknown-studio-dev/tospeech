import Foundation

enum ReviewWordPlayback {
  enum Clock { case source, recording }

  static func span(for word: LessonWord, clock: Clock, evidence: PronunciationEvidence?) -> AudioSpan? {
    let assessed = evidence?.words.first { $0.id == word.id }
    let span: AudioSpan?
    switch clock {
    case .source:
      if let start = assessed?.target.sourceStart, let end = assessed?.target.sourceEnd {
        span = .init(start: start, end: end)
      } else { span = word.span }
    case .recording:
      // Recording-relative emissions only. Never substitute the reference's
      // timings, or scale the two recordings to the same duration.
      if let start = assessed?.phones.compactMap(\.start).min(),
        let end = assessed?.phones.compactMap(\.end).max() {
        span = .init(start: start, end: end)
      } else { span = nil }
    }
    guard let span, span.start.isFinite, span.end.isFinite, span.start >= 0,
      span.end > span.start else { return nil }
    return span
  }

  static func wordID(at seconds: Double, clock: Clock, sentence: LessonSentence,
    evidence: PronunciationEvidence?) -> String? {
    guard seconds.isFinite, seconds >= 0 else { return nil }
    return sentence.words.first { word in
      guard let span = span(for: word, clock: clock, evidence: evidence) else { return false }
      return seconds >= span.start && seconds < span.end
    }?.id
  }
}
