import Foundation

struct Preferences: Codable, Equatable, Sendable {
  var accent: ReferenceAccent = .uk
  var showIPA = true
  var showTranslation = true
  private var linkingSuggestionsVisible: Bool?
  var showLinking: Bool {
    get { linkingSuggestionsVisible ?? true }
    set { linkingSuggestionsVisible = newValue }
  }
  private var paceHighlightVisible: Bool?
  /// Colours words by the reference speaker's pace and marks pauses.
  var showPace: Bool {
    get { paceHighlightVisible ?? true }
    set { paceHighlightVisible = newValue }
  }
  var speed = 0.75
  var repeats = 5
  var autoRecord = false
  private var enhancedRecordingPlayback: Bool?
  var enhanceRecordings: Bool {
    get { enhancedRecordingPlayback ?? true }
    set { enhancedRecordingPlayback = newValue }
  }
  var countdown = 1.5
  var silence = 2.0
  var maxDuration = 30.0
  var activeEngine: EngineID? = .phone
  var productionAssessmentEngine: EngineID?
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
  /// Optional model identifier for a non-Parakeet transcription adapter; Parakeet ignores it.
  var activeTranscriptionModel: String?
  var video = false
  // Optional storage keeps snapshots written before native-language support
  // decodable; a missing value keeps showing Vietnamese, the original target.
  private var translationLanguageCode: String?
  /// The learner's native language for sentence translations, as a
  /// `Locale.Language.minimalIdentifier` ("vi", "ja", "zh-TW").
  var translationLanguage: String {
    get { translationLanguageCode ?? TranslationLanguage.legacyDefault.id }
    set { translationLanguageCode = newValue }
  }
  /// False until the learner picks a native language; onboarding must not
  /// silently pass a fresh install through with Vietnamese chosen for them.
  var hasChosenTranslationLanguage: Bool { translationLanguageCode != nil }
  var usesTranslation: Bool { translationLanguage != TranslationLanguage.none.id }
  /// Choosing "no translation" hides the translation line; choosing a language
  /// again afterwards shows it, so the learner is not left with a silent toggle.
  mutating func selectTranslationLanguage(_ identifier: String) {
    let wasUsingTranslation = usesTranslation
    translationLanguageCode = identifier
    if !usesTranslation { showTranslation = false } else if !wasUsingTranslation { showTranslation = true }
  }
  // 0 stands for "no time limit"; a missing value keeps the historical 25 s default.
  private var dictationLimitSeconds: Int?
  var dictationTimeLimit: Int? {
    get {
      guard let seconds = dictationLimitSeconds else { return DictationProgress.defaultTimeLimit }
      return seconds == 0 ? nil : seconds
    }
    set { dictationLimitSeconds = newValue ?? 0 }
  }
  // Optional backing keeps older preference snapshots decodable. A missing value
  // means the mandatory first-run setup has not been completed yet.
  private var onboardingCompletion: Bool?
  var hasCompletedOnboarding: Bool {
    get { onboardingCompletion ?? false }
    set { onboardingCompletion = newValue }
  }
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

enum PracticeOptions {
  static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5]
  static let repeatCounts = [1, 3, 5, 10, 20]
  static let countdowns: [Double] = [1.5, 3]
}
