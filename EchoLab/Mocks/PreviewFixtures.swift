import Foundation

enum PreviewFixtures {
  static let simulatedAssessmentScore = 78.0
  static func snapshot() -> PreviewSnapshot {
    let lessons = LessonFixtures.lessons()
    let sentence = lessons[0].sentences[17]
    let takes = [68.0, 76, 82].enumerated().map { index, score in
      PracticeTake(
        id: "fixture-take-\(index)", lessonID: lessons[0].id, sentenceID: sentence.id,
        number: index + 1, createdAt: Date().addingTimeInterval(Double(index - 2) * 86400),
        duration: 5.4, outcome: .complete, sourceSnapshot: sentence, sourceSpeed: 0.75,
        scope: .sentence, wordIDs: sentence.words.map(\.id),
        assessments: [assessment(engine: .gopt, accent: .uk, score: score)])
    }
    return PreviewSnapshot(
      lessons: lessons, takes: takes, preferences: Preferences(), packages: ModelFixtures.packages,
      selectedLessonID: lessons[0].id, selectedSentenceID: sentence.id)
  }
  static func assessment(engine: EngineID, accent: ReferenceAccent, score: Double? = nil)
    -> AssessmentResult
  {
    AssessmentResult(
      id: UUID().uuidString, engine: engine, version: "preview-1", accent: accent,
      configuration: "simulated-mimic-v1", status: score == nil ? .queued : .complete,
      score: score, createdAt: Date())
  }
}
