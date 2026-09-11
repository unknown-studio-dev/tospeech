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

  @Test func allKeysExistInBothCatalogsWithMatchingFormatArguments() throws {
    let english = try catalog(language: "en")
    let vietnamese = try catalog(language: "vi")
    let allKeys = Set(english.keys).union(vietnamese.keys)
    let missingEnglish = allKeys.filter { english[$0] == nil }.sorted()
    let missingVietnamese = allKeys.filter { vietnamese[$0] == nil }.sorted()
    let mismatchedFormats = allKeys.filter { key in
      guard let englishValue = english[key], let vietnameseValue = vietnamese[key] else {
        return false
      }
      return formatSignature(englishValue) != formatSignature(vietnameseValue)
    }.sorted()

    #expect(allKeys.count >= 800)
    #expect(missingEnglish.isEmpty, "Missing English keys: \(missingEnglish)")
    #expect(missingVietnamese.isEmpty, "Missing Vietnamese keys: \(missingVietnamese)")
    #expect(mismatchedFormats.isEmpty, "Format arguments differ: \(mismatchedFormats)")
  }

  @Test func modalCopyResolvesWithoutCrossLanguageFallback() throws {
    let english = try catalog(language: "en")
    let vietnamese = try catalog(language: "vi")
    let examples: [(String, String, String)] = [
      ("Thêm video", "Add video", "Thêm video"),
      ("No audio file selected", "No audio file selected", "Chưa chọn file audio"),
      ("Microphone permission", "Microphone permission", "Quyền micro"),
      ("Word Pronunciation", "Word Pronunciation", "Phát âm từ"),
      ("Preparing waveform from local audio…", "Preparing waveform from local audio…",
        "Đang tạo dạng sóng từ audio trên máy…"),
      ("Only the current unsaved take will be discarded. Earlier takes stay in history.",
        "Only the current unsaved take will be discarded. Earlier takes stay in history.",
        "Chỉ bỏ bản thu hiện tại chưa lưu. Các bản thu trước vẫn được giữ trong lịch sử."),
    ]
    for (key, en, vi) in examples {
      #expect(english[key] == en)
      #expect(vietnamese[key] == vi)
      let copy = EchoCopy(key)
      #expect(copy.resolve(locale: Locale(identifier: "en")) == en)
      #expect(copy.resolve(locale: Locale(identifier: "vi")) == vi)
    }
  }



  @Test func importRecoveryCopyIsLocalizedWithoutLeakingDiagnostics() throws {
    let english = try catalog(language: "en")
    let vietnamese = try catalog(language: "vi")
    let errors: [ProductionImportError] = [
      .invalidYouTubeURL, .inaccessibleLocalAudio, .duplicateIdentity, .cancelled,
      .modelNotInstalled, .unsupportedMedia("private diagnostic"),
      .persistence("private diagnostic"), .recoveryRequired("private diagnostic"),
      .staleGeneration(expected: 2),
    ]
    for error in errors {
      let key = error.presentationDescription
      #expect(english[key] != nil)
      #expect(vietnamese[key] != nil)
      #expect(english[key] != vietnamese[key])
      #expect(!key.contains("private diagnostic"))
    }
  }

  private func catalog(language: String) throws -> [String: String] {
    let url = try #require(Bundle.main.url(
      forResource: "Localizable", withExtension: "strings",
      subdirectory: nil, localization: language))
    let data = try Data(contentsOf: url)
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
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
