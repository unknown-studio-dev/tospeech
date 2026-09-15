import Foundation

/// A self-assessed starting level. It is never stored: choosing one rewrites the
/// concrete practice preferences below, which the learner then tunes directly.
enum LearnerLevel: String, CaseIterable, Identifiable, Sendable {
  case beginning, basicConversation, confidentConversation

  var id: String { rawValue }

  var title: String {
    switch self {
    case .beginning: "Mới bắt đầu"
    case .basicConversation: "Giao tiếp cơ bản"
    case .confidentConversation: "Giao tiếp tự tin"
    }
  }

  var detail: String {
    switch self {
    case .beginning: "Mình cần nhiều thời gian để nghe và nhắc lại."
    case .basicConversation: "Mình hiểu phần chính và muốn nói liền mạch hơn."
    case .confidentConversation: "Mình muốn tinh chỉnh nhịp, âm và độ tự nhiên."
    }
  }

  var speed: Double { self == .beginning ? 0.75 : 1 }

  var repeats: Int {
    switch self {
    case .beginning: 5
    case .basicConversation: 3
    case .confidentConversation: 1
    }
  }

  var countdown: Double { self == .beginning ? 3 : 1.5 }
  var showsTranslation: Bool { self != .confidentConversation }
  var autoRecords: Bool { self == .confidentConversation }

  /// nil means the learner writes without a clock.
  var dictationTimeLimit: Int? {
    switch self {
    case .beginning: nil
    case .basicConversation: 25
    case .confidentConversation: 15
    }
  }

  func apply(to preferences: inout Preferences) {
    preferences.speed = speed
    preferences.repeats = repeats
    preferences.countdown = countdown
    preferences.showTranslation = showsTranslation && preferences.usesTranslation
    preferences.autoRecord = autoRecords
    preferences.dictationTimeLimit = dictationTimeLimit
  }

  /// The level whose preset the preferences currently match, if any. Compares
  /// the values themselves, so an old snapshot's implicit 25 s still matches.
  static func matching(_ preferences: Preferences) -> LearnerLevel? {
    allCases.first { level in
      preferences.speed == level.speed && preferences.repeats == level.repeats
        && preferences.countdown == level.countdown
        && preferences.showTranslation == (level.showsTranslation && preferences.usesTranslation)
        && preferences.autoRecord == level.autoRecords
        && preferences.dictationTimeLimit == level.dictationTimeLimit
    }
  }
}
