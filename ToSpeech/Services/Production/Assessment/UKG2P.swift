import Foundation

/// Dictionary-first target generation. eSpeak is a local spelling-to-IPA
/// fallback within the selected UK package, not an acoustic grading model. It
/// serves both accents (voices `en-gb` and `en-us`); the type keeps its original
/// name so the project file stays untouched.
actor UKG2P {
  let package: UKReferencePackage
  private let runner = SubprocessRunner()
  private var cache: [String: OfflineIPAPronunciation] = [:]
  init(package: UKReferencePackage) { self.package = package }
  func pronunciation(_ word: String, accent: ReferenceAccent = .uk) async throws -> OfflineIPAPronunciation {
    guard let value = try await pronunciations([word], accent: accent)[word] else { throw UKReferenceError.phones }
    return value
  }
  func pronunciations(_ words: [String], accent: ReferenceAccent = .uk) async throws -> [String: OfflineIPAPronunciation] {
    let missing = Set(words).filter { cache[Self.cacheKey($0, accent)] == nil }.sorted()
    if !missing.isEmpty {
      let directory = try await package.validate()
      let executable = try await package.helperExecutable()
      for word in missing {
        cache[Self.cacheKey(word, accent)] = try await generate(word, accent: accent, directory: directory, executable: executable)
      }
    }
    return Dictionary(uniqueKeysWithValues: Set(words).compactMap { word in cache[Self.cacheKey(word, accent)].map { (word, $0) } })
  }
  private static func cacheKey(_ word: String, _ accent: ReferenceAccent) -> String { "\(accent.rawValue):\(word)" }
  private func generate(_ word: String, accent: ReferenceAccent, directory: URL, executable: URL) async throws -> OfflineIPAPronunciation {
    guard !word.isEmpty, word.count <= 80, word.contains(where: { $0.isLetter || $0.isNumber }),
      word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "'" || $0 == "’" || $0 == "-" }) else { throw UKReferenceError.phones }
    try Task.checkCancellation()
    let runner = self.runner
    let voice = accent == .uk ? "en-gb" : "en-us"
    let output = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await runner.run(executable: executable,
          // eSpeak's data-path buffer is shorter than valid macOS container paths.
          // Resolve data relative to the explicitly selected package directory.
          arguments: ["--path=.", "-q", "--ipa=1", "-v", voice, "--", word],
          currentDirectory: directory).standardOutput
      }
      group.addTask { try await Task.sleep(for: .seconds(5)); throw UKReferenceError.phones }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    try Task.checkCancellation()
    guard output.utf8.count <= 4096 else { throw UKReferenceError.phones }
    let ipa = accent == .uk ? Self.normalized(output) : Self.normalizedUS(output)
    if accent == .uk {
      guard UKPhoneInventory.parse(ipa) != nil else { throw UKReferenceError.phones }
    } else {
      guard !ipa.isEmpty, !ipa.contains(where: \.isWhitespace) else { throw UKReferenceError.phones }
    }
    return OfflineIPAPronunciation(ipa: ipa, source: "eSpeak NG \(voice) generated IPA", sourceRevision: "1.52.0")
  }
  nonisolated static func normalized(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "_").map { token in
      var text = String(token)
      let stress = text.filter { $0 == "ˈ" || $0 == "ˌ" }
      text.removeAll { $0 == "ˈ" || $0 == "ˌ" }
      // eSpeak en-gb writes the TRAP lexical vowel as /a/; preserve diphthongs.
      if text == "a" { text = "æ" }
      return stress+text
    }.joined()
  }
  /// eSpeak en-us keeps length marks and writes NURSE as /ɜː/; the bundled US
  /// dictionary (ipa-dict) uses /ɝ/ and no length marks, so match that style.
  nonisolated static func normalizedUS(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "_").map { token in
      var text = String(token)
      let stress = text.filter { $0 == "ˈ" || $0 == "ˌ" }
      text.removeAll { $0 == "ˈ" || $0 == "ˌ" }
      if text == "ɜː" { text = "ɝ" }
      text.removeAll { $0 == "ː" }
      return stress+text
    }.joined()
  }
}
