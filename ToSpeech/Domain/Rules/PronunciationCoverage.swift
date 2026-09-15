import Foundation

enum PhoneAssessmentAvailability: String, Codable, Sendable {
  case outsideModel, referenceUncertain, takeUncertain, unavailable, referenceUnmapped, referenceWeak, modelCannotDistinguish
  var title: String { "review.availability.\(rawValue)" }
}

/// Coverage is separate from correctness. A partially assessed word is never
/// promoted to an all-correct word simply because its few graded phones match.
struct PronunciationCoverage {
  enum Summary: String {
    case unassessed, partial, focus, matched
    var title: String { "review.drawer.\(rawValue)" }
    var symbol: String {
      switch self {
      case .unassessed, .partial: "questionmark"
      case .focus: "waveform.badge.exclamationmark"
      case .matched: "checkmark"
      }
    }
  }

  var counts: [PronunciationQuality: Int] = [:]
  var reasons: [PhoneAssessmentAvailability: Int] = [:]
  var total: Int { counts.values.reduce(0, +) }
  var assessed: Int { total - counts[.unassessed, default: 0] }
  var summary: Summary {
    guard assessed > 0 else { return .unassessed }
    guard assessed == total else { return .partial }
    if counts[.incorrect, default: 0] > 0 || counts[.nearCorrect, default: 0] > 0 {
      return .focus
    }
    return .matched
  }

  init(_ evidence: PronunciationEvidence) {
    for word in evidence.words {
      for phone in word.phones {
        counts[PronunciationDisplay.quality(phone, supported: word.supported), default: 0] += 1
        if let reason = Self.reason(phone, word: word, evidence: evidence) {
          reasons[reason, default: 0] += 1
        }
      }
    }
  }

  static func reason(_ phone: PhoneDifference, word: WordPronunciationEvidence,
    evidence: PronunciationEvidence) -> PhoneAssessmentAvailability? {
    guard PronunciationDisplay.quality(phone, supported: word.supported) == .unassessed else { return nil }
    if let stored = phone.unassessedReason { return stored }
    if !word.supported { return .unavailable }
    if phone.kind == .referenceUncertain { return .referenceUncertain }
    if phone.kind == .uncertain { return .takeUncertain }
    // This historical policy returned scored/unassessed exclusively for labels
    // outside its nine-category head. Do not infer coverage for unknown engines.
    if evidence.qualityPolicy == UKReferenceQuality.policy, phone.kind == .scored {
      return .outsideModel
    }
    return .unavailable
  }
}
