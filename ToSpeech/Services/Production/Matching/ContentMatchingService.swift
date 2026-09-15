import CryptoKit
import Foundation
import Observation
import OSLog

/// One durable queue shared by every lesson. Jobs snapshot the selected ASR;
/// there is no automatic model download, engine fallback or pronunciation score.
@MainActor @Observable
final class ContentMatchingService {
  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let adapters: TranscriptionAdapterRegistry
  private var worker: Task<Void, Never>?
  private(set) var jobs: [ContentMatchingJob] = []
  private(set) var error: String?
  var practiceIsBusy: @MainActor () -> Bool = { false }

  init(database: ProductionDatabase, paths: BackendPaths, adapters: TranscriptionAdapterRegistry) {
    self.database = database
    self.paths = paths
    self.adapters = adapters
  }

  func history(takeID: UUID) -> [ContentMatchingJob] { jobs.filter { $0.takeID == takeID } }

  func enqueue(_ take: ProductionStoredTake, preferences: Preferences) async {
    guard take.status == "ready", [.complete, .earlyStop].contains(take.outcome) else { return }
    let selection = TranscriptionSelection(engineID: preferences.transcriptionEngine,
      modelID: preferences.transcriptionEngine == "parakeet"
        ? TranscriptionSelection.parakeet.modelID : (preferences.activeTranscriptionModel ?? ""))
    await enqueue(takeID: take.id, selection: selection,
      locale: preferences.accent == .uk ? "en-GB" : "en-US", force: false)
  }

  func retry(_ job: ContentMatchingJob) async {
    await enqueue(takeID: job.takeID, selection: job.selection, locale: job.locale,
      force: true, retainedProvenance: job.provenance)
  }

  func rerun(_ take: ProductionStoredTake, preferences: Preferences) async {
    let selection = TranscriptionSelection(engineID: preferences.transcriptionEngine,
      modelID: preferences.transcriptionEngine == "parakeet"
        ? TranscriptionSelection.parakeet.modelID : (preferences.activeTranscriptionModel ?? ""))
    await enqueue(takeID: take.id, selection: selection,
      locale: preferences.accent == .uk ? "en-GB" : "en-US", force: true)
  }

  private func enqueue(takeID: UUID, selection: TranscriptionSelection, locale: String, force: Bool,
    retainedProvenance: TranscriptionProvenance? = nil) async {
    do {
      let adapter = try adapters.adapter(for: selection)
      // Persist even when installation is missing; the worker records an actionable failure.
      _ = try await database.enqueueContentMatching(takeID: takeID, selection: selection,
        locale: locale, provenance: try retainedProvenance ?? adapter.provenance(modelID: selection.modelID, locale: locale), force: force)
      error = nil
      await reload()
      startWorker()
    } catch { report(error) }
  }

  func recover() async {
    error = nil
    await reload()
    startWorker()
  }

  private func reload() async {
    do { jobs = try await database.contentMatchingJobs() }
    catch { report(error) }
  }

  private func startWorker() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      defer { self.worker = nil }
      while !Task.isCancelled {
        await self.reload()
        guard var job = self.jobs.first(where: { $0.isPending }) else { return }
        // Do not start a model load in the middle of playback/countdown/capture.
        if self.practiceIsBusy() {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          continue
        }
        do {
          job.status = .running
          try await self.database.updateContentMatching(job)
          await self.reload()
          let url = self.paths.finalTakes.appendingPathComponent("\(job.takeID.uuidString).caf")
          let checksum = try await Task.detached(priority: .utility) {
            try Self.checksum(url)
          }.value
          guard checksum == job.audioChecksum else {
            throw ProductionPracticeError.recoveryRequired("The saved take checksum changed.")
          }
          let adapter = try self.adapters.adapter(for: job.selection)
          let currentProvenance = try adapter.provenance(modelID: job.selection.modelID, locale: job.locale)
          guard currentProvenance == job.provenance else {
            throw ProductionPracticeError.recoveryRequired("The ASR runtime changed. Run again with the current model.")
          }
          try await adapter.validate(modelID: job.selection.modelID)
          let output = try await adapter.transcribe(audioURL: url,
            modelID: job.selection.modelID, locale: job.locale, onProgress: { _ in })
          guard output.provenance == job.provenance else {
            throw ProductionPracticeError.recoveryRequired("ASR provenance did not match the queued job.")
          }
          let match = try ContentMatch.compare(expected: job.target.text,
            observed: output.words.map(\.text).joined(separator: " "))
          job.transcription = output
          job.match = match
          job.status = match.hasRecognizedSpeech ? .complete : .unrecognized
          job.error = nil
        } catch TranscriptionAdapterError.emptyTranscript {
          job.status = .unrecognized
        } catch {
          job.status = .failed
          job.error = error.localizedDescription
          switch error {
          case TranscriptionAdapterError.modelNotInstalled:
            job.errorLocalizationKey = "matching.model_missing"
          case TranscriptionAdapterError.busy:
            job.errorLocalizationKey = "matching.model_busy"
          case ContentMatchingError.tooLong:
            job.errorLocalizationKey = "matching.transcript_too_long"
          default: break
          }
        }
        do { try await self.database.updateContentMatching(job) }
        catch {
          let failure = error
          await self.reload()
          if !self.jobs.contains(where: { $0.id == job.id }) { continue }
          self.report(failure)
          // Retain a pending job on a storage error for explicit retry/relaunch.
          return
        }
      }
    }
  }

  private func report(_ failure: any Error) {
    error = failure.localizedDescription
    Logger(subsystem: "com.unknownstudio.tospeech", category: "ContentMatching")
      .error("Content matching: \(failure.localizedDescription, privacy: .public)")
  }

  nonisolated private static func checksum(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
