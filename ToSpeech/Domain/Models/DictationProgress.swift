import Foundation

struct DictationAttempt: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let answer: String
  let targetText: String
  let comparison: ContentMatch
  let submittedAt: Date
  let timedOut: Bool
  let timeLimit: Int?
  let listenCount: Int
  var matchedCount: Int { comparison.words.filter { $0.kind == .matched }.count }
  var targetCount: Int { comparison.words.filter { $0.expected != nil }.count }
  var isExact: Bool { comparison.differences.isEmpty }
}

struct DictationDraft: Codable, Equatable, Sendable {
  var answer = ""
  var hasListened = false
  var listenCount = 0
  var timeLimit: Int? = 25
  var remainingSeconds: Double? = 25
  var submitted = false

  init(timeLimit: Int? = 25) {
    self.timeLimit = timeLimit
    remainingSeconds = timeLimit.map(Double.init)
  }
}

/// One immutable transcript revision, with a resumable draft and retained attempts.
struct DictationProgress: Codable, Equatable, Sendable {
  let lessonID: UUID
  let revisionID: UUID
  let targetText: String
  var draft: DictationDraft
  var attempts: [DictationAttempt] = []
  var updatedAt = Date()

  static let timeLimits = [15, 25, 45, 60]
  static let defaultTimeLimit = 25
  var latest: DictationAttempt? { attempts.last }

  func validate() throws {
    guard !ContentMatch.tokens(targetText).isEmpty,
      ContentMatch.tokens(targetText).count <= 512,
      draft.answer.count <= 6_000,
      draft.timeLimit.map({ Self.timeLimits.contains($0) }) ?? true,
      draft.remainingSeconds.map({ $0.isFinite && $0 >= 0 && $0 <= Double(draft.timeLimit ?? 0) }) ?? (draft.timeLimit == nil),
      (draft.timeLimit == nil) == (draft.remainingSeconds == nil),
      draft.listenCount >= 0,
      draft.hasListened == (draft.listenCount > 0),
      ContentMatch.tokens(draft.answer).count <= 512,
      !draft.submitted || !attempts.isEmpty,
      Set(attempts.map(\.id)).count == attempts.count
    else { throw DictationError.invalidProgress }
    for attempt in attempts {
      guard attempt.targetText == targetText, attempt.answer.count <= 6_000,
        attempt.listenCount > 0,
        attempt.timeLimit.map({ Self.timeLimits.contains($0) }) ?? true,
        try ContentMatch.compare(expected: targetText, observed: attempt.answer) == attempt.comparison
      else { throw DictationError.invalidProgress }
    }
  }

  mutating func submit(timedOut: Bool, now: Date) throws {
    guard draft.hasListened, !draft.submitted else { return }
    let comparison = try ContentMatch.compare(expected: targetText, observed: draft.answer)
    attempts.append(.init(id: UUID(), answer: draft.answer, targetText: targetText,
      comparison: comparison, submittedAt: now, timedOut: timedOut,
      timeLimit: draft.timeLimit, listenCount: draft.listenCount))
    draft.submitted = true
    updatedAt = now
  }
}

enum DictationError: Error, LocalizedError {
  case invalidProgress
  var errorDescription: String? { "Invalid dictation progress or transcript revision." }
}
