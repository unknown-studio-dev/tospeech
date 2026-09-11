import Foundation
import WhisperKit

enum WhisperTranscriberError: Error, Equatable, LocalizedError, Sendable {
  case modelNotInstalled
  case downloadFailed(String)
  case transcriptionFailed(String)

  var errorDescription: String? {
    switch self {
    case .modelNotInstalled:
      "A transcription model is required. Download one in Settings before preparing a lesson."
    case .downloadFailed(let detail): "Model download failed: \(detail)"
    case .transcriptionFailed(let detail): "Audio recognition failed: \(detail)"
    }
  }
}

/// Owns the WhisperKit engine (a non-Sendable open class) and never lets it
/// cross an isolation boundary. Install orchestration is downloader-injectable
/// so it is unit-testable without a real model download; only `Sendable`
/// results (`[TimedWord]`) leave the actor.
/// A Sendable value whose stored closure is escaping by nature, so it can be
/// forwarded into WhisperKit's escaping progress callback without capturing a
/// non-escaping parameter.
struct WhisperProgressSink: Sendable {
  let report: @Sendable (Double) -> Void
}

protocol WhisperWordTranscribing: Sendable {
  func transcribe(audioURL: URL, variant: WhisperModelVariant,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord]
}

/// WhisperKit calls progress from detached tasks, so their Task.isCancelled
/// does not reflect the importing task. Relay cancellation explicitly.
final class WhisperCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  var shouldContinue: Bool { lock.withLock { !cancelled } }
}

actor WhisperCaptionTranscriber: WhisperWordTranscribing {
  typealias Downloader = @Sendable (
    _ variant: WhisperModelVariant, _ progress: WhisperProgressSink
  ) async throws -> String

  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let downloader: Downloader
  private var engines: [String: WhisperKit] = [:]

  init(database: ProductionDatabase, paths: BackendPaths, downloader: Downloader? = nil) {
    self.database = database
    self.paths = paths
    self.downloader = downloader ?? Self.liveDownloader(paths: paths)
  }

  func install(
    _ variant: WhisperModelVariant, onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    let releaseID = try await database.registerEngineRelease(
      engineKey: WhisperModelCatalog.engineKey, version: variant.whisperKitModel,
      capabilityJSON: "{}")
    try await database.setEngineInstallationStatus(releaseID: releaseID, status: "downloading")
    do {
      let relativePath = try await downloader(variant, WhisperProgressSink(report: onProgress))
      try await database.setEngineInstallationStatus(releaseID: releaseID, status: "verifying")
      try await database.setEngineInstallationStatus(
        releaseID: releaseID, status: "installed", relativePath: relativePath)
    } catch {
      let message =
        (error as? WhisperTranscriberError).map(\.localizedDescription)
        ?? error.localizedDescription
      try? await database.setEngineInstallationStatus(
        releaseID: releaseID, status: "failed", errorJSON: Self.errorJSON(message))
      throw error
    }
  }

  /// Removes a downloaded model: deletes its files under `paths.packages` and
  /// resets its install row to `not_installed`. Idempotent when not installed.
  func remove(_ variant: WhisperModelVariant) async throws {
    engines[variant.whisperKitModel] = nil
    let releases = try await database.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    guard let record = releases.first(where: { $0.version == variant.whisperKitModel }) else {
      return
    }
    try await database.setEngineInstallationStatus(releaseID: record.id, status: "removing")
    if let relativePath = record.relativePath {
      let folder = paths.root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
      guard folder.path.hasPrefix(paths.packages.resolvingSymlinksInPath().path + "/") else {
        throw WhisperTranscriberError.modelNotInstalled
      }
      if FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
    }
    try await database.setEngineInstallationStatus(
      releaseID: record.id, status: "not_installed", relativePath: nil)
  }

  func transcribe(
    audioURL: URL, variant: WhisperModelVariant,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> [TimedWord] {
    try Task.checkCancellation()
    let releases = try await database.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    guard let installed = releases.first(where: { $0.version == variant.whisperKitModel && $0.status == "installed" }),
      let relative = installed.relativePath else { throw WhisperTranscriberError.modelNotInstalled }
    let folder = paths.root.appendingPathComponent(relative).resolvingSymlinksInPath()
    guard folder.path.hasPrefix(paths.packages.resolvingSymlinksInPath().path + "/"),
      FileManager.default.fileExists(atPath: folder.path) else { throw WhisperTranscriberError.modelNotInstalled }
    defer { engines.removeAll() }
    let engine: WhisperKit
    if let cached = engines[variant.whisperKitModel] {
      engine = cached
    } else {
      do {
        engine = try await WhisperKit(
          WhisperKitConfig(model: variant.whisperKitModel, downloadBase: paths.packages, modelFolder: folder.path, download: false))
      } catch {
        throw WhisperTranscriberError.transcriptionFailed(error.localizedDescription)
      }
      engines[variant.whisperKitModel] = engine
    }
    // WhisperKit's callback is @Sendable and `progress` is a non-Sendable
    // Foundation `Progress`; `Progress` reads are thread-safe, so the tracker
    // captures a reference explicitly marked unsafe for the concurrency checker.
    try Task.checkCancellation()
    let cancellation = WhisperCancellationState()
    let sink = WhisperProgressSink(report: onProgress)
    nonisolated(unsafe) let progressRef = engine.progress
    let results: [TranscriptionResult]
    do {
      results = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await engine.transcribe(
          audioPath: audioURL.path,
          decodeOptions: DecodingOptions(language: "en", detectLanguage: false, wordTimestamps: true),
          callback: { _ in
            guard cancellation.shouldContinue else { return false }
            sink.report(progressRef.fractionCompleted)
            return cancellation.shouldContinue
          })
      } onCancel: {
        cancellation.cancel()
      }
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw WhisperTranscriberError.transcriptionFailed(error.localizedDescription)
    }
    try Task.checkCancellation()
    // Release the large model before Apple recognition starts.
    engines.removeAll()
    let wordCount = results.flatMap(\.segments).reduce(0) { $0 + ($1.words?.count ?? 0) }
    #if DEBUG
    print("WHISPER_RESULT: results=\(results.count), segments=\(results.flatMap(\.segments).count), words=\(wordCount), textCharacters=\(results.reduce(0) { $0 + $1.text.count })")
    #endif
    return results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
      TimedWord(text: $0.word, start: TimeInterval($0.start), end: TimeInterval($0.end))
    }
  }

  private static func errorJSON(_ message: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: ["reason": message])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  private static func liveDownloader(paths: BackendPaths) -> Downloader {
    { variant, progress in
      let folder = try await WhisperKit.download(
        variant: variant.whisperKitModel, downloadBase: paths.packages,
        progressCallback: { progress.report($0.fractionCompleted) })
      let rootPath = paths.root.path
      let full = folder.path
      if full.hasPrefix(rootPath) {
        return String(full.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
      }
      return full
    }
  }
}
