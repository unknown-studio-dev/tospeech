import Foundation
import Testing
@testable import ToSpeech

@Suite("Translation languages")
struct TranslationLanguageTests {
  @Test func vietnameseKeepsTheOriginalAnnotationKey() {
    let vietnamese = TranslationLanguage(Locale.Language(identifier: "vi-Latn-VN"))
    #expect(vietnamese.id == "vi")
    #expect(vietnamese.lookupKey == "sentence:vi")
    #expect(TranslationLanguage.legacyDefault == vietnamese)
    #expect(TranslationLanguage(Locale.Language(identifier: "zh-Hant-TW")).id == "zh-TW")
    #expect(TranslationLanguage(Locale.Language(identifier: "zh-Hans-CN")).id == "zh")
  }

  @Test func englishIsNeverOfferedAsANativeLanguage() {
    #expect(TranslationLanguage(identifier: "en").isEnglish)
    #expect(TranslationLanguage(identifier: "en-GB").isEnglish)
    #expect(!TranslationLanguage(identifier: "vi").isEnglish)
    #expect(!TranslationLanguageCatalog.fallback.contains { $0.isEnglish })
    #expect(TranslationLanguageCatalog.fallback.contains(.legacyDefault))
  }

  @Test func namesSpellOutTheScriptOnlyWhenTwoChineseVariantsAreOffered() {
    let english = Locale(identifier: "en")
    let offered = TranslationLanguageCatalog.fallback
    // macOS formats this as "Chinese, Simplified"; only the parts are pinned, not the punctuation.
    let simplified = TranslationLanguage(identifier: "zh").name(in: english, among: offered)
    let traditional = TranslationLanguage(identifier: "zh-TW").name(in: english, among: offered)
    #expect(simplified.hasPrefix("Chinese") && simplified.contains("Simplified"))
    #expect(traditional.hasPrefix("Chinese") && traditional.contains("Traditional"))
    #expect(TranslationLanguage(identifier: "zh").name(in: english) == "Chinese", "Alone, no script is spelled out")
    #expect(TranslationLanguage(identifier: "ar-AE").name(in: english, among: offered) == "Arabic")
    #expect(TranslationLanguage(identifier: "vi").title(in: english, among: offered) == "Tiếng Việt · Vietnamese")
    #expect(TranslationLanguage(identifier: "vi").title(in: Locale(identifier: "vi"), among: offered) == "Tiếng Việt")
  }

  @Test func deviceDefaultMatchesByLanguageAndScriptAndSkipsUnsupportedLanguages() {
    let offered = TranslationLanguageCatalog.fallback
    #expect(TranslationLanguage.deviceDefault(among: offered, preferred: ["vi-VN"])?.id == "vi")
    #expect(TranslationLanguage.deviceDefault(among: offered, preferred: ["zh-Hant-TW"])?.id == "zh-TW")
    #expect(TranslationLanguage.deviceDefault(among: offered, preferred: ["zh-Hans-CN"])?.id == "zh")
    #expect(TranslationLanguage.deviceDefault(among: offered, preferred: ["en-US", "ja-JP"])?.id == "ja")
    #expect(TranslationLanguage.deviceDefault(among: offered, preferred: ["en-US"]) == nil)
  }
}
