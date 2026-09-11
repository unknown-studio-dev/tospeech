import Foundation

enum PracticePhase: String {
  case idle, listening, countdown, awaitingSpeech, recording, trailingSilence, saving, saveFailed,
    paused, feedback
  var isCapture: Bool { [.awaitingSpeech, .recording, .trailingSilence].contains(self) }
  var title: String {
    switch self {
    case .idle: "Ready to listen"
    case .listening: "Listening · microphone off"
    case .countdown: "Get ready to speak"
    case .awaitingSpeech: "Waiting for your voice"
    case .recording: "Recording your take"
    case .trailingSilence: "Finishing after silence"
    case .saving: "Saving your take…"
    case .saveFailed: "Your take needs to be saved"
    case .paused: "Loop paused"
    case .feedback: "Take saved"
    }
  }
}

enum CaptureOutcome: String, CaseIterable, Codable, Sendable {
  case complete, noSpeech, quiet, earlyStop, interrupted
  var label: String {
    switch self {
    case .complete: "Complete"
    case .noSpeech: "No speech detected"
    case .quiet: "Voice too quiet"
    case .earlyStop: "Check early stop"
    case .interrupted: "Interrupted"
    }
  }
}

enum PracticeScope: String, Codable, Sendable { case sentence, phrase }
enum AssessmentStatus: String, Codable, Sendable {
  case queued, running, complete, failed, cancelled
}

struct AssessmentResult: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var engine: EngineID
  var version: String
  var accent: ReferenceAccent
  var configuration: String
  var status: AssessmentStatus
  var score: Double?
  var error: String?
  var createdAt: Date
  var profile: String { "\(engine.rawValue)/\(version)/\(accent.rawValue)/\(configuration)" }
}

struct PracticeTake: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var lessonID: String
  var sentenceID: String
  var number: Int
  var createdAt: Date
  var duration: Double
  var outcome: CaptureOutcome
  var sourceSnapshot: LessonSentence
  var sourceSpeed: Double
  var scope: PracticeScope
  var wordIDs: [String]
  var assessments: [AssessmentResult]
  var latestAssessment: AssessmentResult? { assessments.last }
}
