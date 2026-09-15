import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
  case english = "en"
  case vietnamese = "vi"

  var id: String { rawValue }
  var locale: Locale { Locale(identifier: rawValue) }

  var titleKey: String {
    switch self {
    case .english: "language.english"
    case .vietnamese: "language.vietnamese"
    }
  }

  static var deviceDefault: AppLanguage {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("vi") == true ? .vietnamese : .english
  }
}
