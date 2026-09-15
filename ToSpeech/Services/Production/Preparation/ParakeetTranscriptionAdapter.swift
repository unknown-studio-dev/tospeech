import CoreML
import FluidAudio
import Foundation
import OSLog

/// The only production file that knows FluidAudio's model and token APIs.
actor ParakeetTranscriptionAdapter: TranscriptionAdapter {
  nonisolated let engineID = "parakeet"
  static let modelID = TranscriptionSelection.parakeet.modelID
  static let releaseKey = "parakeet-transcription"
  static let runtime = "FluidAudio 0.15.7; encoder int8; cpuAndNeuralEngine"
  private let database: ProductionDatabase
  private let paths: BackendPaths
  private var busy = false

  init(database: ProductionDatabase, paths: BackendPaths) {
    self.database = database
    self.paths = paths
  }

  private var directory: URL {
    paths.packages.appendingPathComponent("FluidAudio/" + Repo.parakeetV3.folderName, isDirectory: true)
  }

  nonisolated func provenance(modelID: String, locale: String) throws -> TranscriptionProvenance {
    guard modelID == Self.modelID else { throw TranscriptionAdapterError.unsupportedModel(modelID) }
    return TranscriptionProvenance(engine: "FluidAudio", model: modelID,
      localeIdentifier: "en", runtimeVersion: Self.runtime)
  }

  func validate(modelID: String) async throws {
    guard modelID == Self.modelID else { throw TranscriptionAdapterError.unsupportedModel(modelID) }
    let records = try await database.engineReleases(engineKey: Self.releaseKey)
    guard records.contains(where: { $0.version == modelID && $0.status == "installed" }),
      AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
    else { throw TranscriptionAdapterError.modelNotInstalled }
  }

  func installed() async throws -> Bool {
    do { try await validate(modelID: Self.modelID); return true }
    catch TranscriptionAdapterError.modelNotInstalled { return false }
  }

  func install(onProgress: @escaping @Sendable (Double) -> Void) async throws {
    guard !busy else { throw TranscriptionAdapterError.busy }
    busy = true
    defer { busy = false }
    try paths.prepare()
    let id = try await database.registerEngineRelease(engineKey: Self.releaseKey,
      version: Self.modelID, capabilityJSON: "{\"runtime\":\"FluidAudio 0.15.7\",\"precision\":\"int8\",\"license\":\"CC-BY-4.0\"}")
    try await database.setEngineInstallationStatus(releaseID: id, status: "downloading")
    do {
      _ = try await AsrModels.download(to: directory, version: .v3, encoderPrecision: .int8,
        progressHandler: { onProgress($0.fractionCompleted) })
      try Task.checkCancellation()
      try await database.setEngineInstallationStatus(releaseID: id, status: "verifying")
      // A DB row alone is not an installation: load all four CoreML components and vocabulary.
      _ = try await loadInstalledModels()
      try Task.checkCancellation()
      try await database.setEngineInstallationStatus(releaseID: id, status: "installed",
        relativePath: "Packages/FluidAudio/" + Repo.parakeetV3.folderName)
    } catch {
      do { try await database.setEngineInstallationStatus(releaseID: id, status: "failed") }
      catch { Logger(subsystem: "com.unknownstudio.tospeech", category: "Parakeet").error("Cannot record failed installation: \(error)") }
      throw error
    }
  }

  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    guard !busy else { throw TranscriptionAdapterError.busy }
    busy = true
    defer { busy = false }
    try Task.checkCancellation()
    try await validate(modelID: modelID)
    let models = try await loadInstalledModels()
    try Task.checkCancellation()
    // One worker bounds CPU/memory pressure; file input uses SDK disk-backed chunking.
    let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
    let stream = await manager.transcriptionProgressStream
    let observer = Task {
      do {
        for try await value in stream {
          try Task.checkCancellation()
          onProgress(value)
        }
      } catch { /* The transcription call below reports the same terminal failure. */ }
    }
    do {
      var state = try TdtDecoderState()
      let result = try await manager.transcribe(audioURL, decoderState: &state, language: .english)
      observer.cancel()
      await manager.cleanup()
      try Task.checkCancellation()
      let words = Self.words(from: result.tokenTimings ?? [])
      guard !words.isEmpty else { throw TranscriptionAdapterError.emptyTranscript }
      onProgress(1)
      return AudioTranscription(words: words, source: .parakeet,
        provenance: try provenance(modelID: modelID, locale: locale))
    } catch {
      observer.cancel()
      await manager.cleanup()
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw error
    }
  }

  nonisolated static func words(from timings: [TokenTiming]) -> [TimedWord] {
    buildWordTimings(from: timings).map {
      TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
    }
  }

  /// Load strictly from managed files. SDK `load` can download missing files;
  /// constructing AsrModels directly prevents network recovery during recognition.
  private func loadInstalledModels() async throws -> AsrModels {
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine
    let cpu = MLModelConfiguration()
    cpu.computeUnits = .cpuOnly
    let folder = directory
    let preprocessor = try await MLModel.load(contentsOf: folder.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: cpu)
    try Task.checkCancellation()
    let encoder = try await MLModel.load(contentsOf: folder.appendingPathComponent(ParakeetEncoderPrecision.int8.encoderFileName), configuration: config)
    try Task.checkCancellation()
    let decoder = try await MLModel.load(contentsOf: folder.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: config)
    let joint = try await MLModel.load(contentsOf: folder.appendingPathComponent(ModelNames.ASR.jointV3File), configuration: config)
    let raw = try JSONDecoder().decode([String: String].self,
      from: Data(contentsOf: folder.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
    let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value -> (Int, String)? in
      Int(key).map { ($0, value) }
    })
    guard !vocabulary.isEmpty else { throw TranscriptionAdapterError.modelNotInstalled }
    return AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder,
      joint: joint, configuration: config, vocabulary: vocabulary, version: .v3)
  }
}
