import Foundation
@preconcurrency import Translation

/// Asks Apple Translation which native languages English lessons can be
/// translated into on this Mac. Nothing here downloads a package: that consent
/// stays with the SwiftUI `translationTask` host.
enum TranslationLanguageCatalog {
  /// Shown until Apple Translation answers, and wherever it cannot be asked
  /// (previews, tests). Mirrors the macOS 26 list minus English.
  static let fallback: [TranslationLanguage] = [
    "vi", "zh", "zh-TW", "ja", "ko", "th", "id", "hi", "ar-AE", "ru", "uk", "pl", "tr", "de", "fr",
    "es", "it", "pt", "nl",
  ].map(TranslationLanguage.init(identifier:))

  static func supported() async -> [TranslationLanguage] {
    let availability = LanguageAvailability()
    var values: [TranslationLanguage] = []
    for language in await availability.supportedLanguages {
      let value = TranslationLanguage(language)
      guard !value.isEnglish, !values.contains(value) else { continue }
      switch await availability.status(from: AppleTranslationPreparer.source, to: language) {
      case .installed, .supported: values.append(value)
      case .unsupported: continue
      @unknown default: continue
      }
    }
    return values.isEmpty ? fallback : values
  }

  static func isInstalled(_ language: TranslationLanguage) async -> Bool {
    await LanguageAvailability().status(from: AppleTranslationPreparer.source, to: language.language)
      == .installed
  }
}
