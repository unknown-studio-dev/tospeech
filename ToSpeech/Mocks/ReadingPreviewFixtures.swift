import Foundation

enum ReadingPreviewFixtures {
  static var feedbackStates: [(name: String, take: PracticeTake)] {
    guard let original = PreviewFixtures.snapshot().takes.last else { return [] }
    return ["pending", "complete", "failed", "no-speech", "unscored", "cancelled"].map { name in
      var take = original
      switch name {
      case "pending": take.assessments[0].status = .running
      case "failed": take.assessments[0].status = .failed
      case "no-speech":
        take.outcome = .noSpeech
        take.assessments = []
      case "unscored": take.assessments = []
      case "cancelled": take.assessments[0].status = .cancelled
      default: break
      }
      return (name, take)
    }
  }
}
