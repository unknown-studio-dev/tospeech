import Foundation

struct Preferences: Codable, Equatable, Sendable {
  var accent: ReferenceAccent = .uk
  var showIPA = true
  var showTranslation = true
  var speed = 0.75
  var repeats = 5
  var autoRecord = false
  var countdown = 1.5
  var silence = 2.0
  var maxDuration = 30.0
  var activeEngine: EngineID? = .phone
  // Optional backing fields preserve snapshots created before engine selection.
  private var transcriptionEngineID: String?
  var transcriptionEngine: String {
    get { transcriptionEngineID ?? "parakeet" }
    set { transcriptionEngineID = newValue }
  }
  private var appleTranscriptComparison: Bool?
  var compareTranscriptWithApple: Bool {
    get { appleTranscriptComparison ?? true }
    set { appleTranscriptComparison = newValue }
  }
  /// Preserve the selected Whisper variant when switching to another engine.
  var activeTranscriptionModel: String?
  var video = false
  var learningGoal: LearningGoal?
  var selfAssessedLevel: SelfAssessedLevel?
  // Optional storage keeps snapshots written before app-language support decodable.
  private var languageCode: String?
  var language: AppLanguage {
    get { languageCode.flatMap(AppLanguage.init(rawValue:)) ?? .deviceDefault }
    set { languageCode = newValue.rawValue }
  }
  // Optional storage keeps snapshots written before this preference decodable.
  private var readingSizePercent: Int?
  var readingPercent: Int {
    get { ReadingSize.normalized(readingSizePercent ?? ReadingSize.defaultPercent) }
    set { readingSizePercent = ReadingSize.normalized(newValue) }
  }
}

enum LearningGoal: String, Codable, CaseIterable, Sendable {
  case listening, speaking
  var title: String {
    switch self {
    case .listening: "Nghe và bắt kịp câu"
    case .speaking: "Nói rõ và tự nhiên hơn"
    }
  }
}

enum SelfAssessedLevel: String, Codable, CaseIterable, Sendable {
  case beginning, basicConversation, confidentConversation
  var title: String {
    switch self {
    case .beginning: "Mới bắt đầu"
    case .basicConversation: "Giao tiếp cơ bản"
    case .confidentConversation: "Giao tiếp tự tin"
    }
  }
}

enum PracticeOptions {
  static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5]
  static let repeatCounts = [1, 3, 5, 10, 20]
  static let countdowns: [Double] = [1.5, 3]
}
