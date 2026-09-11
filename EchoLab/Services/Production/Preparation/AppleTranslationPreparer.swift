import Foundation
@preconcurrency import Translation

struct SentenceTranslationValue: Codable, Equatable, Sendable {
  let text: String
  let sourceLanguage: String
  let targetLanguage: String
}

enum AppleTranslationPreparationError: Error, Equatable, LocalizedError {
  case unsupported
  case notReady
  case responseMismatch

  var errorDescription: String? {
    switch self {
    case .unsupported: "English to Vietnamese translation is not supported on this Mac."
    case .notReady: "The English to Vietnamese translation package is not ready."
    case .responseMismatch:
      "Translation returned a response that could not be matched to its sentence."
    }
  }
}

/// Owns only local Apple Translation orchestration. The SwiftUI host supplies a
/// TranslationSession through `translationTask`, allowing macOS to manage first
/// download consent; this service never replaces it with a cloud provider.
@MainActor
final class AppleTranslationPreparer {
  static let source = Locale.Language(identifier: "en")
  static let target = Locale.Language(identifier: "vi")

  private let database: ProductionDatabase

  init(database: ProductionDatabase) { self.database = database }

  func availability() async -> LanguageAvailability.Status {
    await LanguageAvailability().status(from: Self.source, to: Self.target)
  }

  func prepare(using session: TranslationSession) async throws {
    try await session.prepareTranslation()
    guard await session.isReady else { throw AppleTranslationPreparationError.notReady }
  }

  func translate(lessonID: UUID, using session: TranslationSession) async throws {
    guard await session.isReady else { throw AppleTranslationPreparationError.notReady }
    let targets = try await database.preparationTargets(lessonID: lessonID)
    let requests = targets.map {
      TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.revisionID.uuidString)
    }
    // Translation's SDK has not yet annotated Request as Sendable. Requests are
    // immutable values created and consumed on this MainActor-only call path.
    nonisolated(unsafe) let requestBatch = requests
    let responses = try await session.translations(from: requestBatch)
    for response in responses {
      guard let identifier = response.clientIdentifier,
        let revisionID = UUID(uuidString: identifier)
      else { throw AppleTranslationPreparationError.responseMismatch }
      let value = SentenceTranslationValue(
        text: response.targetText,
        sourceLanguage: response.sourceLanguage.languageCode?.identifier ?? "und",
        targetLanguage: response.targetLanguage.languageCode?.identifier ?? "und")
      try await database.storeAutomaticAnnotation(
        revisionID: revisionID, kind: .translation, lookupKey: "sentence:vi",
        source: "apple-translation", value: try JSONEncoder().encode(value))
    }
  }
}
