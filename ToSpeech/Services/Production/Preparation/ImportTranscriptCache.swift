import Foundation
import OSLog

struct ImportTranscriptCacheIdentity: Codable, Equatable, Sendable {
  let sourceChecksum: String
  let engine: String
  let model: String
  let locale: String
  let runtime: String
  let formatVersion: Int
}

private struct ImportTranscriptCacheEntry<Value: Codable>: Codable {
  let identity: ImportTranscriptCacheIdentity
  let value: Value
}

/// Successful engine output is staged independently, so a later merge/publish
/// error does not force expensive recognition to run again. Cache identity
/// includes the audio bytes, selected model, locale and extraction version.
enum ImportTranscriptCache {
  static func load<Value: Codable>(
    _ type: Value.Type, from url: URL, identity: ImportTranscriptCacheIdentity
  ) -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let entry = try JSONDecoder().decode(ImportTranscriptCacheEntry<Value>.self, from: Data(contentsOf: url))
      guard entry.identity == identity else { return nil }
      return entry.value
    } catch {
      Logger(subsystem: "com.unknownstudio.tospeech", category: "ImportTranscriptCache")
        .warning("Discard invalid staged transcript; rerun the same engine: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  static func save<Value: Codable>(
    _ value: Value, to url: URL, identity: ImportTranscriptCacheIdentity
  ) throws {
    try JSONEncoder().encode(ImportTranscriptCacheEntry(identity: identity, value: value))
      .write(to: url, options: .atomic)
  }
}

enum TranscriptPreparationError: Error, LocalizedError, Sendable {
  case emptyPrimary
  case emptyApple
  case noTimedSentences

  var errorDescription: String? {
    switch self {
    case .emptyPrimary: "The transcription engine returned no word transcript for this audio."
    case .emptyApple: "Apple SpeechTranscriber returned no transcript for this audio."
    case .noTimedSentences: "The recognized transcript has no sentence within the source audio timeline."
    }
  }
}
