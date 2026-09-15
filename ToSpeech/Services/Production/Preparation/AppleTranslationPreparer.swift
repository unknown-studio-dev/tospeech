import Foundation
@preconcurrency import Translation

struct SentenceTranslationValue: Codable, Equatable, Sendable {
  let text: String
  let sourceLanguage: String
  let targetLanguage: String
}

enum AppleTranslationPreparationError: Error, Equatable, LocalizedError, EchoCopyConvertible {
  case unsupported
  case notReady
  case responseMismatch

  var errorDescription: String? {
    switch self {
    case .unsupported: "Translating English into the chosen language is not supported on this Mac."
    case .notReady: "The translation package for the chosen language is not ready."
    case .responseMismatch:
      "Translation returned a response that could not be matched to its sentence."
    }
  }

  var copy: EchoCopy {
    switch self {
    case .unsupported: EchoCopy("translation.error.unsupported")
    case .notReady: EchoCopy("translation.error.not_ready")
    case .responseMismatch: EchoCopy("translation.error.mismatch")
    }
  }
}

/// Owns only local Apple Translation orchestration. The SwiftUI host supplies a
/// TranslationSession through `translationTask`, allowing macOS to manage first
/// download consent; this service never replaces it with a cloud provider.
@MainActor
final class AppleTranslationPreparer {
  static let source = Locale.Language(identifier: "en")

  private let database: ProductionDatabase

  init(database: ProductionDatabase) { self.database = database }

  static func configuration(for language: TranslationLanguage) -> TranslationSession.Configuration {
    TranslationSession.Configuration(source: source, target: language.language)
  }

  func availability(for language: TranslationLanguage) async -> LanguageAvailability.Status {
    await LanguageAvailability().status(from: Self.source, to: language.language)
  }

  func prepare(using session: TranslationSession) async throws {
    try await session.prepareTranslation()
    guard await session.isReady else { throw AppleTranslationPreparationError.notReady }
  }

  /// Translates only the sentences that have no translation in `language` yet, so
  /// reopening a lesson is free and switching native language costs one pass.
  func translate(
    lessonID: UUID, into language: TranslationLanguage, using session: TranslationSession
  ) async throws {
    guard !language.isNone else { return }
    guard await session.isReady else { throw AppleTranslationPreparationError.notReady }
    let targets = try await database.preparationTargets(
      lessonID: lessonID, missingTranslation: language.lookupKey)
    guard !targets.isEmpty else { return }
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
        revisionID: revisionID, kind: .translation, lookupKey: language.lookupKey,
        source: "apple-translation", value: try JSONEncoder().encode(value))
    }
  }
}
