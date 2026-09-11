import Foundation
import Testing
@testable import EchoLab

@Suite("Localization")
struct LocalizationTests {
  @Test @MainActor func catalogsResolveEnglishAndVietnameseCopy() {
    #expect(
      EchoLocalization.string("Cài đặt", locale: Locale(identifier: "en")) == "Settings")
    #expect(
      EchoLocalization.string("Settings", locale: Locale(identifier: "vi")) == "Cài đặt")
    #expect(
      EchoLocalization.string("language.vietnamese", locale: Locale(identifier: "en"))
        == "Vietnamese")
    #expect(
      EchoLocalization.string("language.english", locale: Locale(identifier: "vi"))
        == "Tiếng Anh")
    #expect(
      EchoLocalization.format(
        "transport.round", locale: Locale(identifier: "en"),
        arguments: [3, 5, "Listening"]) == "Round 3 / 5 · Listening")
    #expect(
      EchoLocalization.format(
        "transport.round", locale: Locale(identifier: "vi"),
        arguments: [3, 5, "Đang nghe"]) == "Vòng 3 / 5 · Đang nghe")
    #expect(
      EchoLocalization.format(
        "import.presentation.progress.position", locale: Locale(identifier: "en"),
        arguments: [3, 4]) == "Step 3 / 4")
    #expect(
      EchoLocalization.string(
        "import.presentation.ready.start", locale: Locale(identifier: "vi")) == "Bắt đầu luyện")
  }

  @Test func languagePreferenceRoundTripsAndOldSnapshotsRemainDecodable() throws {
    var preferences = Preferences()
    preferences.language = .vietnamese
    let data = try JSONEncoder().encode(preferences)
    #expect(try JSONDecoder().decode(Preferences.self, from: data).language == .vietnamese)

    var oldObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    oldObject.removeValue(forKey: "languageCode")
    let oldData = try JSONSerialization.data(withJSONObject: oldObject)
    #expect(try JSONDecoder().decode(Preferences.self, from: oldData).language == .deviceDefault)
  }

  @Test @MainActor func restoringDemoKeepsTheChosenInterfaceLanguage() {
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    store.preferences.language = .vietnamese
    store.restoreDemo()
    #expect(store.preferences.language == .vietnamese)
  }

  @Test @MainActor func changingLanguageDoesNotInterruptPracticeOrMoveTheAudioClock() {
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    store.practice.playSentence(repeating: true)
    store.practice.advance(by: 0.5)
    let position = store.practice.sourcePosition

    store.preferences.language = .vietnamese

    #expect(store.practice.phase == .listening)
    #expect(store.practice.sourcePosition == position)
    store.practice.interrupt()
  }

  @Test @MainActor func dynamicCopyLocalizesItsTemplateAndLocalizedArgumentsAtRenderTime() {
    let copy = EchoCopy(
      "preview.labeled_range",
      arguments: [.localized("Original word"), .raw("1.20"), .raw("1.75"), .raw("0.75")])

    #expect(
      copy.resolve(locale: Locale(identifier: "en"))
        == "Original word · 1.20–1.75s · 0.75× · simulated")
    #expect(
      copy.resolve(locale: Locale(identifier: "vi"))
        == "Từ trong audio gốc · 1.20–1.75 giây · 0.75× · mô phỏng")
  }

  @Test func semanticKeysExistInBothCatalogsWithMatchingFormatArguments() throws {
    let english = try catalog(language: "en")
    let vietnamese = try catalog(language: "vi")
    let semanticKeys = Set(english.keys).union(vietnamese.keys).filter(isSemanticKey)
    let missingEnglish = semanticKeys.filter { english[$0] == nil }.sorted()
    let missingVietnamese = semanticKeys.filter { vietnamese[$0] == nil }.sorted()
    let mismatchedFormats = semanticKeys.filter { key in
      guard let englishValue = english[key], let vietnameseValue = vietnamese[key] else {
        return false
      }
      return formatSignature(englishValue) != formatSignature(vietnameseValue)
    }.sorted()

    #expect(semanticKeys.count >= 54)
    #expect(missingEnglish.isEmpty, "Missing English keys: \(missingEnglish)")
    #expect(missingVietnamese.isEmpty, "Missing Vietnamese keys: \(missingVietnamese)")
    #expect(mismatchedFormats.isEmpty, "Format arguments differ: \(mismatchedFormats)")
  }



  private func catalog(language: String) throws -> [String: String] {
    let url = try #require(Bundle.main.url(
      forResource: "Localizable", withExtension: "strings",
      subdirectory: nil, localization: language))
    let data = try Data(contentsOf: url)
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
  }

  private func isSemanticKey(_ key: String) -> Bool {
    let parts = key.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, let first = parts.first?.first, first.isLowercase else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }
  }

  private func formatSignature(_ value: String) -> [String] {
    let specifiers = Set("diuoxXfFeEgGaAcCsSp@")
    let modifiers = Set("0123456789$-+0 #*.")
    var result: [String] = []
    var cursor = value.startIndex
    while let percent = value[cursor...].firstIndex(of: "%") {
      var index = value.index(after: percent)
      guard index < value.endIndex else { break }
      if value[index] == "%" {
        cursor = value.index(after: index)
        continue
      }
      var token = "%"
      while index < value.endIndex {
        let character = value[index]
        token.append(character)
        index = value.index(after: index)
        if specifiers.contains(character) {
          result.append(token)
          break
        }
        if !modifiers.contains(character) { break }
      }
      cursor = index
    }
    return result
  }
}
