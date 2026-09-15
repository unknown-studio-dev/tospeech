import Foundation

/// Spelling-to-IPA generator consulted only for words the bundled dictionary
/// lacks; the app wires eSpeak NG through `UKG2P`.
typealias IPAFallback = @Sendable (_ word: String, _ accent: ReferenceAccent) async throws -> OfflineIPAPronunciation?

/// Persists dictionary results by immutable revision/token/accent. A later
/// dictionary refresh can change automatic data while an explicit user choice
/// remains in `override_value`.
actor IPAAnnotationPreparer {
  private let database: ProductionDatabase
  private let dictionary: OfflineIPADictionary
  private let fallback: IPAFallback?

  init(database: ProductionDatabase, dictionary: OfflineIPADictionary, fallback: IPAFallback? = nil) {
    self.database = database
    self.dictionary = dictionary
    self.fallback = fallback
  }

  func prepare(lessonID: UUID) async throws {
    let targets = try await database.preparationTargets(lessonID: lessonID)
    for target in targets {
      for token in target.tokens {
        for accent in ReferenceAccent.allCases {
          let pronunciations = try await IPAAnnotationBuilder.lookup(
            token.text, accent: accent, dictionary: dictionary, fallback: fallback)
          guard !pronunciations.isEmpty else { continue }
          let value = IPAAnnotationValue(accent: accent, pronunciations: pronunciations)
          let encoded = try JSONEncoder().encode(value)
          try await database.storeAutomaticAnnotation(
            revisionID: target.revisionID, kind: .ipa,
            lookupKey: "\(token.id):\(accent.rawValue.lowercased())",
            source: pronunciations[0].source, value: encoded)
        }
      }
    }
  }
}

enum IPAAnnotationBuilder {
  /// Dictionary first; the generator only for pronounceable spellings the
  /// dictionary does not know. A generator failure leaves the word without IPA
  /// rather than failing the whole lesson.
  static func lookup(
    _ text: String, accent: ReferenceAccent, dictionary: OfflineIPADictionary, fallback: IPAFallback?
  ) async throws -> [OfflineIPAPronunciation] {
    let found = try await dictionary.pronunciations(for: text, accent: accent)
    if !found.isEmpty { return found }
    let key = OfflineIPADictionary.lookupKey(for: text)
    guard let fallback, key.contains(where: \.isLetter) else { return [] }
    guard let generated = try? await fallback(key, accent) else { return [] }
    return [generated]
  }

  static func build(
    segments: [PreparedLessonSegment], dictionary: OfflineIPADictionary, fallback: IPAFallback? = nil
  ) async throws -> [PreparedLessonAnnotation] {
    var result: [PreparedLessonAnnotation] = []
    for segment in segments {
      let tokens = try JSONDecoder().decode(
        [TranscriptWordToken].self, from: Data(segment.tokensJSON.utf8))
      for token in tokens {
        for accent in ReferenceAccent.allCases {
          let pronunciations = try await lookup(token.text, accent: accent, dictionary: dictionary, fallback: fallback)
          guard !pronunciations.isEmpty else { continue }
          let value = IPAAnnotationValue(accent: accent, pronunciations: pronunciations)
          result.append(
            PreparedLessonAnnotation(
              segmentID: segment.id, kind: .ipa,
              lookupKey: "\(token.id):\(accent.rawValue.lowercased())",
              source: pronunciations[0].source,
              automaticValue: try JSONEncoder().encode(value)))
        }
      }
    }
    return result
  }
}
