import Foundation

/// A native language the learner reads sentence translations in. `id` is the
/// language's minimal identifier ("vi", "ja", "zh-TW"), which doubles as the
/// annotation key suffix so the original `sentence:vi` rows keep matching.
struct TranslationLanguage: Identifiable, Hashable, Sendable {
  let id: String

  init(identifier: String) { id = identifier }
  init(_ language: Locale.Language) { id = language.minimalIdentifier }

  /// Vietnamese was the only target before learners could choose one.
  static let legacyDefault = TranslationLanguage(identifier: "vi")
  /// The learner reads no translation at all (their language is not offered,
  /// or they prefer English only). Matches no annotation and downloads nothing.
  static let none = TranslationLanguage(identifier: "none")
  var isNone: Bool { id == Self.none.id }

  var language: Locale.Language { Locale.Language(identifier: id) }
  var lookupKey: String { Self.lookupKey(id) }
  static func lookupKey(_ identifier: String) -> String { "sentence:\(identifier)" }

  /// Lessons are English, so English is never offered as a translation target.
  var isEnglish: Bool { language.languageCode?.identifier == "en" }

  /// The name shown in `locale`, spelling out the script only when another
  /// offered language shares the same code ("Chinese (Simplified)").
  func name(in locale: Locale, among offered: [TranslationLanguage] = []) -> String {
    let code = language.languageCode?.identifier ?? id
    let shared = offered.contains { $0.id != id && $0.language.languageCode?.identifier == code }
    let maximal = Locale.Language(identifier: language.maximalIdentifier)
    let identifier = shared ? [code, maximal.script?.identifier].compactMap { $0 }.joined(separator: "-") : code
    return locale.localizedString(forIdentifier: identifier) ?? id
  }

  /// "Tiếng Việt · Vietnamese": the endonym first, then the name in the app language.
  func title(in locale: Locale, among offered: [TranslationLanguage] = []) -> String {
    let name = name(in: locale, among: offered)
    let endonym = self.name(in: Locale(identifier: id), among: offered)
    return endonym == name ? name : "\(endonym) · \(name)"
  }

  /// Picks the offered language matching the Mac's preferred languages, comparing
  /// language code and script so "zh-Hant-TW" finds Traditional Chinese.
  static func deviceDefault(
    among offered: [TranslationLanguage], preferred: [String] = Locale.preferredLanguages
  ) -> TranslationLanguage? {
    for identifier in preferred {
      let wanted = Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
      if let match = offered.first(where: { candidate in
        let maximal = Locale.Language(identifier: candidate.language.maximalIdentifier)
        return maximal.languageCode == wanted.languageCode && maximal.script == wanted.script
      }) { return match }
    }
    return nil
  }

  static func sorted(_ languages: [TranslationLanguage], locale: Locale) -> [TranslationLanguage] {
    languages.sorted {
      $0.name(in: locale, among: languages).localizedStandardCompare($1.name(in: locale, among: languages))
        == .orderedAscending
    }
  }
}
