import Foundation

/// Persisted with each job. Retries keep the same engine/model even after Settings changes.
struct TranscriptionSelection: Codable, Equatable, Sendable {
  let engineID: String
  let modelID: String

  static let parakeet = TranscriptionSelection(engineID: "parakeet", modelID: "parakeet-tdt-0.6b-v3")
}

/// SDK-independent boundary: import only consumes words, observed times and provenance.
/// Installing packages is a separate, explicit operation owned by each adapter.
protocol TranscriptionAdapter: Sendable {
  var engineID: String { get }
  func validate(modelID: String) async throws
  func provenance(modelID: String, locale: String) throws -> TranscriptionProvenance
  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription
}

struct TranscriptionAdapterRegistry: Sendable {
  private let adapters: [String: any TranscriptionAdapter]

  init(_ adapters: [any TranscriptionAdapter]) {
    self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.engineID, $0) })
  }

  func adapter(for selection: TranscriptionSelection) throws -> any TranscriptionAdapter {
    guard let adapter = adapters[selection.engineID] else {
      throw TranscriptionAdapterError.unsupportedModel(selection.engineID + "/" + selection.modelID)
    }
    return adapter
  }
}

enum TranscriptionAdapterError: Error, LocalizedError, Sendable {
  case unsupportedModel(String)
  case modelNotInstalled
  case emptyTranscript
  case busy

  var errorDescription: String? {
    switch self {
    case .unsupportedModel(let model): "Unsupported transcription model: \(model)"
    case .modelNotInstalled: "A transcription model is required. Download one in Settings before preparing a lesson."
    case .emptyTranscript: "The selected engine returned no usable word transcript for this audio."
    case .busy: "This transcription engine is already processing another operation. Retry after it finishes."
    }
  }
}

struct WhisperTranscriptionAdapter: TranscriptionAdapter {
  let engineID = "whisper"
  let transcriber: any WhisperWordTranscribing
  let database: ProductionDatabase

  private func variant(_ modelID: String) throws -> WhisperModelVariant {
    guard let variant = WhisperModelVariant(rawValue: modelID) else {
      throw TranscriptionAdapterError.unsupportedModel(modelID)
    }
    return variant
  }

  func validate(modelID: String) async throws {
    let variant = try variant(modelID)
    guard WhisperModelSelection.active(
      from: try await database.engineReleases(engineKey: WhisperModelCatalog.engineKey),
      selected: variant.rawValue) != nil else { throw TranscriptionAdapterError.modelNotInstalled }
  }

  func provenance(modelID: String, locale: String) throws -> TranscriptionProvenance {
    TranscriptionProvenance(engine: "WhisperKit", model: try variant(modelID).whisperKitModel,
      localeIdentifier: "en", runtimeVersion: "WhisperKit 1.1.0")
  }

  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    let words = try await transcriber.transcribe(audioURL: audioURL, variant: variant(modelID), onProgress: onProgress)
    guard !words.isEmpty else { throw TranscriptionAdapterError.emptyTranscript }
    return AudioTranscription(words: words, source: .whisper,
      provenance: try provenance(modelID: modelID, locale: locale))
  }
}

struct TranscriptionProvenance: Codable, Equatable, Sendable {
  let engine: String
  let model: String
  let localeIdentifier: String
  /// Apple does not expose a model revision; record the OS build, not a guessed version.
  let runtimeVersion: String
}

struct AudioTranscription: Codable, Sendable {
  let words: [TimedWord]
  let source: TranscriptSource
  let provenance: TranscriptionProvenance
}

protocol AudioTranscriptTranscribing: Sendable {
  func prepare(localeIdentifier: String) async throws
  func prepareForComparison(localeIdentifier: String) async throws
  func transcribe(
    audioURL: URL, localeIdentifier: String,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> AudioTranscription
}


extension AudioTranscriptTranscribing {
  func prepareForComparison(localeIdentifier: String) async throws {
    try await prepare(localeIdentifier: localeIdentifier)
  }
}
