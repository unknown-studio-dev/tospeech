import Foundation

/// Persists dictionary results by immutable revision/token/accent. A later
/// dictionary refresh can change automatic data while an explicit user choice
/// remains in `override_value`.
actor IPAAnnotationPreparer {
  private let database: ProductionDatabase
  private let dictionary: OfflineIPADictionary

  init(database: ProductionDatabase, dictionary: OfflineIPADictionary) {
    self.database = database
    self.dictionary = dictionary
  }

  func prepare(lessonID: UUID) async throws {
    let targets = try await database.preparationTargets(lessonID: lessonID)
    for target in targets {
      for token in target.tokens {
        for accent in ReferenceAccent.allCases {
          let pronunciations = try await dictionary.pronunciations(for: token.text, accent: accent)
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
  static func build(
    segments: [PreparedLessonSegment], dictionary: OfflineIPADictionary
  ) async throws -> [PreparedLessonAnnotation] {
    var result: [PreparedLessonAnnotation] = []
    for segment in segments {
      let tokens = try JSONDecoder().decode(
        [TranscriptWordToken].self, from: Data(segment.tokensJSON.utf8))
      for token in tokens {
        for accent in ReferenceAccent.allCases {
          let pronunciations = try await dictionary.pronunciations(for: token.text, accent: accent)
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
