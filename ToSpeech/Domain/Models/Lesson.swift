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

  /// The IPA to show for `accent`, falling back to the other accent when the
  /// requested one is empty (common for proper nouns absent from the British
  /// RP dictionary). `fallbackAccent` is non-nil only when a substitution
  /// happened, so the view can mark it (dimmed + accent label) rather than
  /// presenting the other accent's pronunciation as if it were the requested one.
  func resolvedIPA(for accent: ReferenceAccent) -> ResolvedIPA? {
    if let primary = ipa(for: accent), !primary.isEmpty {
      return ResolvedIPA(text: primary, fallbackAccent: nil)
    }
    let other: ReferenceAccent = accent == .uk ? .us : .uk
    if let fallback = ipa(for: other), !fallback.isEmpty {
      return ResolvedIPA(text: fallback, fallbackAccent: other)
    }
    return nil
  }
}

struct ResolvedIPA: Equatable, Sendable {
  var text: String
  /// The accent actually used when it differs from the requested one; `nil`
  /// when the requested accent supplied the pronunciation.
  var fallbackAccent: ReferenceAccent?
}

/// Normalize notation at the display boundary; dictionary/override values stay intact.
enum IPAFormatting {
  static func isPronounceable(_ text: String) -> Bool {
    text.contains { $0.isLetter || $0.isNumber }
  }

  static func display(_ ipa: String?) -> String? {
    guard let ipa else { return nil }
    let content = ipa.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/[]")))
    return content.isEmpty ? nil : "/\(content)/"
  }
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
