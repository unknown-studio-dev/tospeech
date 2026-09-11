import Foundation

enum ReferenceAccent: String, CaseIterable, Codable, Identifiable, Sendable {
  case uk = "UK"
  case us = "US"
  var id: String { rawValue }
}

struct AudioSpan: Codable, Equatable, Sendable {
  var start: Double
  var end: Double
  var duration: Double { end - start }
  func isValid(duration: Double) -> Bool {
    start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration
  }
}

struct LessonWord: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var text: String
  var ipaUK: String?
  var ipaUS: String?
  var span: AudioSpan?
  var needsTimingReview = false
  func ipa(for accent: ReferenceAccent) -> String? { accent == .uk ? ipaUK : ipaUS }
}

struct SentenceBaseline: Codable, Equatable, Sendable {
  var text: String
  var translation: String
  var span: AudioSpan
  var words: [LessonWord]
}

struct LessonSentence: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var number: Int
  var text: String
  var translation: String
  var span: AudioSpan
  var words: [LessonWord]
  var revision = 1
  var baseline: SentenceBaseline?
  var needsTimingReview: Bool { words.contains { $0.span == nil || $0.needsTimingReview } }
}

struct Lesson: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var title: String
  var author: String
  var thumbnail: String
  var duration: Double
  var accent: ReferenceAccent
  var sourceURL: String?
  var createdAt: Date
  var sentences: [LessonSentence]
}
