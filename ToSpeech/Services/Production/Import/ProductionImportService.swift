import CryptoKit
import Foundation
import OSLog

/// Thread-safe latest-value store for the slow transcription step.
/// Engine progress callbacks fire from a background thread, so this is a
/// lock-guarded box rather than actor state: the callback writes without an
/// await hop, and the UI poll reads the latest fraction on the main actor.
final class TranscriptionProgressTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: Double] = [:]

  func set(_ value: Double, for id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    values[id] = value
  }

  func value(for id: UUID) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    return values[id]
  }

  func clear(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    values[id] = nil
  }
}

actor ProductionImportService {
  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let toolchain: BundledImportToolchain
  private let runner: SubprocessRunner
  private let removeManagedItem: @Sendable (URL) throws -> Void
  private let usesSpeechFallback: Bool
  private let audioTranscriber: (any AudioTranscriptTranscribing)?
  private let transcriptionAdapters: TranscriptionAdapterRegistry?
  private let wordAligner: (any WordAlignmentAdapter)?
  private let ipaDictionary: OfflineIPADictionary?
  private let ipaG2P: UKG2P?
  private let transcriptionProgressTracker = TranscriptionProgressTracker()
  private let logger = Logger(
    subsystem: "com.unknownstudio.tospeech", category: "ProductionImport")
  private struct ActiveImport {
    let lessonID: UUID
    let runToken: UUID
    let task: Task<Void, Never>
  }
  private var tasks: [UUID: ActiveImport] = [:]
  private var runtimeFailures: [UUID: ProductionImportJob] = [:]
  private var restartingJobs: Set<UUID> = []

  init(
    database: ProductionDatabase, paths: BackendPaths, toolchain: BundledImportToolchain = .init(),
    runner: SubprocessRunner = .init(),
    usesSpeechFallback: Bool = true,
    audioTranscriber: (any AudioTranscriptTranscribing)? = nil,
    transcriptionAdapters: TranscriptionAdapterRegistry? = nil,
    wordAligner: (any WordAlignmentAdapter)? = nil,
    ipaDictionary: OfflineIPADictionary? = nil,
    ipaG2P: UKG2P? = nil,
    removeManagedItem: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) {
    self.database = database
    self.paths = paths
    self.toolchain = toolchain
    self.runner = runner
    self.usesSpeechFallback = usesSpeechFallback
    self.audioTranscriber = audioTranscriber
    self.transcriptionAdapters = transcriptionAdapters
    self.wordAligner = wordAligner
    self.ipaDictionary = ipaDictionary ?? (try? OfflineIPADictionary.bundled())
    self.ipaG2P = ipaG2P
    self.removeManagedItem = removeManagedItem
  }

  func submit(_ request: ProductionImportRequest, localeIdentifier: String = "en-GB", transcriptionEngine: String = TranscriptionSelection.parakeet.engineID, transcriptionModelID: String? = nil, compareWithApple: Bool = true) async throws -> ProductionImportJob {
    let tools: BundledImportToolchain.Tools
    do { tools = try toolchain.resolve() } catch let error as BundledImportToolchainError {
      throw ProductionImportError.toolchain(error)
    }
    try paths.prepare()
    var identity = try await resolveIdentity(for: request)
    if let existing = try await database.lesson(provider: identity.provider, externalID: identity.externalID) {
      // Keep the identity and attempt history; an unfinished import is resumable,
      // whereas a completed lesson must not be silently replaced.
      guard existing.lifecycle != .ready && existing.lifecycle != .deleting,
        let stored = try await database.unfinishedImportJobs().first(where: {
          (try? decodeInput($0).lessonID) == existing.id
        }) else { throw ProductionImportError.duplicateIdentity }
      if stored.status == "running", tasks[stored.id] != nil,
        let current = try await importJobs().first(where: { $0.id == stored.id }) {
        return current
      }
      return try await retry(jobID: stored.id)
    }
    let lessonID = UUID()
    let jobID = UUID()
    let runToken = UUID()
    let createdAt = Date()
    identity.lessonID = lessonID
    identity.localeIdentifier = localeIdentifier
    if let transcriptionAdapters {
      let selection: TranscriptionSelection
      if let transcriptionModelID {
        selection = TranscriptionSelection(engineID: transcriptionEngine, modelID: transcriptionModelID)
      } else if transcriptionEngine == TranscriptionSelection.parakeet.engineID {
        selection = .parakeet
      } else {
        throw TranscriptionAdapterError.unsupportedModel(transcriptionEngine)
      }
      do { try await transcriptionAdapters.adapter(for: selection).validate(modelID: selection.modelID) }
      catch TranscriptionAdapterError.modelNotInstalled { throw ProductionImportError.modelNotInstalled }
      identity.transcriptionSelection = selection
      identity.compareWithApple = compareWithApple
    }
    do {
      _ = try await database.insertLesson(
        NewLesson(
          id: lessonID, provider: identity.provider, externalID: identity.externalID,
          sourceURL: identity.sourceURL, title: identity.title, createdAt: createdAt))
    } catch ProductionDatabaseError.constraint {
      throw ProductionImportError.duplicateIdentity
    } catch { throw ProductionImportError.persistence(error.localizedDescription) }
    let checkpoint = ImportCheckpoint(
      phase: .resolving, workspaceRelativePath: "Cache/ImportJobs/\(jobID.uuidString)",
      manifestRelativePath: nil, detail: nil, updatedAt: createdAt)
    let checkpointJSON = try json(checkpoint)
    let inputJSON = try json(identity)
    do {
      try await database.persistImportJob(
        id: jobID, lessonID: lessonID, expectedGeneration: 1, runToken: runToken,
        inputJSON: inputJSON,
        checkpointJSON: checkpointJSON, at: createdAt)
    } catch { throw ProductionImportError.persistence(error.localizedDescription) }
    let job = ProductionImportJob(
      id: jobID, lessonID: lessonID, title: identity.title, phase: .resolving, runToken: runToken,
      expectedGeneration: 1, error: nil, createdAt: createdAt, updatedAt: createdAt)
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(job: job, input: identity, tools: tools)
    }
    tasks[jobID] = ActiveImport(lessonID: lessonID, runToken: runToken, task: task)
    return job
  }
  func librarySummaries() async throws -> [LibraryLessonSummary] {
    try await database.librarySummaries(paths: paths)
  }

  func importJobs() async throws -> [ProductionImportJob] {
    let storedJobs = try await database.unfinishedImportJobs()
    let storedIDs = Set(storedJobs.map(\.id))
    runtimeFailures = runtimeFailures.filter { storedIDs.contains($0.key) }
    return try storedJobs.map { stored in
      if let runtimeFailure = runtimeFailures[stored.id] { return runtimeFailure }
      let input = try decodeInput(stored)
      guard let lessonID = input.lessonID,
        let checkpoint = try? JSONDecoder().decode(
          ImportCheckpoint.self, from: Data(stored.checkpointJSON.utf8))
      else {
        throw ProductionImportError.recoveryRequired("Stored import checkpoint is invalid.")
      }
      let error: ProductionImportError? =
        checkpoint.phase == .failed
        ? .recoveryRequired(checkpoint.detail ?? "Import failed.")
        : checkpoint.phase == .cancelled ? .cancelled : nil
      return ProductionImportJob(
        id: stored.id, lessonID: lessonID, title: input.title, phase: checkpoint.phase,
        runToken: stored.runToken, expectedGeneration: stored.expectedGeneration, error: error,
        createdAt: checkpoint.updatedAt, updatedAt: checkpoint.updatedAt)
    }
  }

  func cancel(jobID: UUID) async {
    tasks[jobID]?.task.cancel()
  }

  /// Sub-progress (0...1) of the in-flight transcription step for a job, if one
  /// is running. `nil` when the job is in a different phase or has finished.
  nonisolated func transcriptionProgress(jobID: UUID) -> Double? {
    transcriptionProgressTracker.value(for: jobID)
  }

  func retryUsingSettings(jobID: UUID, engine: String, compareWithApple: Bool) async throws -> ProductionImportJob {
    let selection = TranscriptionSelection(engineID: engine, modelID: TranscriptionSelection.parakeet.modelID)
    return try await retry(jobID: jobID, replacementSelection: selection, compareWithApple: compareWithApple)
  }

  @discardableResult
  func retry(jobID: UUID, replacementSelection: TranscriptionSelection? = nil, compareWithApple: Bool? = nil) async throws -> ProductionImportJob {
    guard restartingJobs.insert(jobID).inserted else {
      throw ProductionImportError.recoveryRequired("An import restart is already in progress.")
    }
    defer { restartingJobs.remove(jobID) }
    // Never run two decoders or mutate one staging folder concurrently.
    if let previous = tasks[jobID] {
      previous.task.cancel()
      await previous.task.value
    }
    let stored = try await database.unfinishedImportJobs().first(where: { $0.id == jobID })
    guard let stored else {
      throw ProductionImportError.recoveryRequired("Import job no longer exists.")
    }
    var input = try JSONDecoder().decode(StoredInput.self, from: Data(stored.inputJSON.utf8))
    if let replacementSelection {
      guard let transcriptionAdapters else { throw TranscriptionAdapterError.unsupportedModel(replacementSelection.engineID) }
      try await transcriptionAdapters.adapter(for: replacementSelection).validate(modelID: replacementSelection.modelID)
      let previous = input.transcriptionSelection
      let manifest = paths.importWorkspace(for: jobID).appendingPathComponent("commit-manifest.json")
      if previous != replacementSelection && FileManager.default.fileExists(atPath: manifest.path) {
        throw ProductionImportError.recoveryRequired("This lesson is already prepared. Use Retry to finish saving it before importing with another model.")
      }
      if let previous, previous != replacementSelection {
        input.previousTranscriptionSelections = (input.previousTranscriptionSelections ?? []) + [previous]
      }
      input.transcriptionSelection = replacementSelection
      input.compareWithApple = compareWithApple ?? input.compareWithApple
    }
    guard let lessonID = input.lessonID else {
      throw ProductionImportError.recoveryRequired("Import job has no lesson identity.")
    }
    let tools = try toolchain.resolve()
    runtimeFailures[jobID] = nil
    let runToken = try await database.beginImportRetry(
      id: stored.id, expectedGeneration: stored.expectedGeneration, replacementInputJSON: replacementSelection == nil ? nil : try json(input))
    let job = ProductionImportJob(
      id: stored.id, lessonID: lessonID, title: input.title, phase: .resolving,
      runToken: runToken, expectedGeneration: stored.expectedGeneration, error: nil,
      createdAt: Date(), updatedAt: Date())
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(job: job, input: input, tools: tools)
    }
    tasks[jobID] = ActiveImport(lessonID: lessonID, runToken: runToken, task: task)
    return job
  }

  func resumePendingJobs() async throws {
    var recoveryFailure: (any Error)?
    for lesson in try await database.deletingLessons() {
      do { try await resumeDeletion(lesson) } catch {
        if recoveryFailure == nil { recoveryFailure = error }
      }
    }
    let jobs = try await database.unfinishedImportJobs()
    let running = jobs.filter { $0.status == "running" && tasks[$0.id] == nil }
    if !running.isEmpty {
      let tools = try toolchain.resolve()
      for stored in running {
        let input: StoredInput
        do { input = try decodeInput(stored) } catch {
          if recoveryFailure == nil { recoveryFailure = error }
          continue
        }
        guard let lessonID = input.lessonID else {
          if recoveryFailure == nil {
            recoveryFailure = ProductionImportError.recoveryRequired(
              "Stored import has no lesson identity.")
          }
          continue
        }
        let job = ProductionImportJob(
          id: stored.id, lessonID: lessonID, title: input.title, phase: .resolving,
          runToken: stored.runToken, expectedGeneration: stored.expectedGeneration,
          error: nil, createdAt: Date(), updatedAt: Date())
        let task = Task { [weak self] in
          guard let self else { return }
          await self.run(job: job, input: input, tools: tools)
        }
        tasks[stored.id] = ActiveImport(
          lessonID: lessonID, runToken: stored.runToken, task: task)
      }
    }
    if let recoveryFailure { throw recoveryFailure }
  }

  func deleteLesson(id: UUID, expectedGeneration: Int) async throws {
    try paths.prepare()
    for importTask in tasks.values where importTask.lessonID == id {
      importTask.task.cancel()
    }
    let assets = try await database.assetsForLessonDeletion(lessonID: id)
    let intentURL = paths.deletionManifest(for: id)
    let provisional = DeletionManifest(
      lessonID: id, expectedGeneration: expectedGeneration + 1, assets: assets)
    try Data(try json(provisional).utf8).write(to: intentURL, options: .atomic)
    var markedDeleting = false
    do {
      let deletingGeneration = try await database.markLessonDeleting(
        id: id, expectedGeneration: expectedGeneration)
      markedDeleting = true
      guard deletingGeneration == provisional.expectedGeneration else {
        throw ProductionImportError.staleGeneration(expected: expectedGeneration)
      }
      try await completeDeletion(provisional, manifestURL: intentURL)
    } catch {
      if !markedDeleting { removeBestEffort(intentURL, operation: "Remove unused deletion intent") }
      throw error
    }
  }

  func deletingLessonIDs() async throws -> [UUID] {
    try await database.deletingLessons().map(\.id)
  }

  func retryDeletion(id: UUID) async throws {
    guard let lesson = try await database.deletingLessons().first(where: { $0.id == id }) else {
      throw ProductionImportError.recoveryRequired("Deletion intent no longer exists.")
    }
    try await resumeDeletion(lesson)
  }

  private func resumeDeletion(_ lesson: DeletingLesson) async throws {
    let manifestURL = paths.deletionManifest(for: lesson.id)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw ProductionImportError.recoveryRequired("Deletion manifest is missing.")
    }
    let manifest = try JSONDecoder().decode(
      DeletionManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.lessonID == lesson.id, manifest.expectedGeneration == lesson.generation else {
      throw ProductionImportError.recoveryRequired("Deletion manifest does not match the lesson.")
    }
    try await completeDeletion(manifest, manifestURL: manifestURL)
  }

  private func completeDeletion(_ manifest: DeletionManifest, manifestURL: URL) async throws {
    for asset in manifest.assets {
      guard !asset.relativePath.hasPrefix("/"),
        !asset.relativePath.split(separator: "/").contains("..")
      else {
        throw ProductionImportError.persistence("Stored asset path escaped the managed root.")
      }
      let url = paths.root.appendingPathComponent(asset.relativePath)
      if FileManager.default.fileExists(atPath: url.path) { try removeManagedItem(url) }
      if url.deletingLastPathComponent().standardizedFileURL == paths.finalTakes.standardizedFileURL,
        url.pathExtension == "caf" {
        let trimReceipt = RecordingSilenceTrimmer.receiptURL(for: url)
        if FileManager.default.fileExists(atPath: trimReceipt.path) { try removeManagedItem(trimReceipt) }
      }
    }
    try await database.completeLessonDeletion(
      lessonID: manifest.lessonID, expectedGeneration: manifest.expectedGeneration)
    removeBestEffort(manifestURL, operation: "Remove completed deletion intent")
  }

  private func run(
    job: ProductionImportJob, input: StoredInput, tools: BundledImportToolchain.Tools
  ) async {
    do {
      try Task.checkCancellation()
      try await checkpoint(job, .resolving, detail: nil)
      let workspace = paths.importWorkspace(for: job.id)
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      let audio = workspace.appendingPathComponent("source.m4a")
      let thumbnail = workspace.appendingPathComponent("thumbnail.jpg")
      let vttCaption = workspace.appendingPathComponent("captions.vtt")
      let speechCaption = workspace.appendingPathComponent("captions.json")
      let manifestURL = workspace.appendingPathComponent("commit-manifest.json")
      if FileManager.default.fileExists(atPath: manifestURL.path) {
        let manifest = try JSONDecoder().decode(
          CommitManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.lessonID == job.lessonID,
          manifest.expectedGeneration == job.expectedGeneration
        else {
          throw ProductionImportError.recoveryRequired(
            "Import manifest does not match this lesson.")
        }
        for asset in manifest.assets {
          let finalURL = paths.root.appendingPathComponent(asset.relativePath)
          guard FileManager.default.fileExists(atPath: finalURL.path),
            try sha256(finalURL) == asset.checksum
          else {
            throw ProductionImportError.recoveryRequired(
              "Published import bytes are missing or changed.")
          }
        }
        let ready = ImportCheckpoint(
          phase: .ready, workspaceRelativePath: manifest.workspaceRelativePath,
          manifestRelativePath: "Cache/ImportJobs/\(job.id.uuidString)/commit-manifest.json",
          detail: nil, updatedAt: Date())
        try await publish(
          manifest: manifest, job: job, checkpointJSON: try json(ready))
        removeBestEffort(workspace, operation: "Remove replayed import workspace")
        if tasks[job.id]?.runToken == job.runToken { tasks[job.id] = nil }
        return
      }
      var retainedProbe: AudioProbe?
      if FileManager.default.fileExists(atPath: audio.path) {
        retainedProbe = try? await probe(audio, with: tools.ffprobe, in: workspace)
        if retainedProbe == nil { try FileManager.default.removeItem(at: audio) }
      }
      if !FileManager.default.fileExists(atPath: audio.path) {
        try await checkpoint(job, .downloadingAudio, detail: nil)
        switch input.kind {
        case .youtube:
          _ = try await runner.run(
            executable: tools.ytDLP,
            arguments: [
              "--no-config", "--no-update", "--no-playlist", "--js-runtimes",
              "quickjs:\(tools.qjs.path)",
              "-f", "bestaudio", "--ffmpeg-location",
              tools.ffmpeg.deletingLastPathComponent().path,
              "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
              "--write-subs", "--sub-langs", "en.*", "--sub-format", "vtt",
              "-o", "\(workspace.path)/%(id)s.%(ext)s", input.sourceURL.absoluteString,
            ], currentDirectory: workspace)
          let candidates = try FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil)
          // The stream stays in its native container; one ffmpeg pass levels it
          // into the stored AAC instead of transcoding twice.
          guard let downloaded = candidates.first(where: {
            Self.downloadedAudioExtensions.contains($0.pathExtension.lowercased())
              && $0.lastPathComponent != audio.lastPathComponent
          }) else {
            throw ProductionImportError.unsupportedMedia("yt-dlp did not produce an audio source")
          }
          guard let image = candidates.first(where: { $0.pathExtension.lowercased() == "jpg" })
          else {
            throw ProductionImportError.unsupportedMedia("yt-dlp did not produce a JPEG thumbnail")
          }
          try await writeLevelledSource(from: downloaded, to: audio, tools: tools, in: workspace)
          removeBestEffort(downloaded, operation: "Remove downloaded audio stream")
          if FileManager.default.fileExists(atPath: thumbnail.path) {
            try FileManager.default.removeItem(at: thumbnail)
          }
          try FileManager.default.moveItem(at: image, to: thumbnail)
        case .localAudio:
          let scoped = input.securityScoped == true
          let access = scoped ? input.sourceURL.startAccessingSecurityScopedResource() : true
          defer { if scoped && access { input.sourceURL.stopAccessingSecurityScopedResource() } }
          guard access, FileManager.default.isReadableFile(atPath: input.sourceURL.path) else {
            throw ProductionImportError.inaccessibleLocalAudio
          }
          try await writeLevelledSource(from: input.sourceURL, to: audio, tools: tools, in: workspace)
        }
      }
      var resolvedTitle = input.title
      var resolvedAuthor: String?
      if input.kind == .youtube {
        guard
          let infoURL = try FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil
          ).first(where: {
            $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".info.json")
          })
        else { throw ProductionImportError.unsupportedMedia("yt-dlp metadata is missing") }
        let metadata: YouTubeMetadata
        do {
          metadata = try JSONDecoder().decode(YouTubeMetadata.self, from: Data(contentsOf: infoURL))
        } catch { throw ProductionImportError.unsupportedMedia("yt-dlp metadata is invalid") }
        if input.title == input.externalID { resolvedTitle = metadata.title }
        resolvedAuthor = metadata.uploader ?? metadata.channel
      }
      try await checkpoint(job, .probing, detail: nil)
      let resolvedProbe: AudioProbe
      if let retainedProbe {
        resolvedProbe = retainedProbe
      } else {
        resolvedProbe = try await probe(audio, with: tools.ffprobe, in: workspace)
      }
      var preparedSegments: [PreparedLessonSegment]?
      var captionAsset: MediaAsset?
      var stagedCaption: URL?
      if let transcriptionAdapters {
        // Jobs written before the adapter registry only carried a Whisper variant; that
        // engine is gone, so such jobs must be retried with the current engine.
        guard let selection = input.transcriptionSelection else {
          throw ProductionImportError.recoveryRequired("This import was started with a transcription engine that is no longer available. Retry it from Settings with the current engine.")
        }
        let adapter = try transcriptionAdapters.adapter(for: selection)
        let locale = input.localeIdentifier ?? "en-GB"
        let provenance = try adapter.provenance(modelID: selection.modelID, locale: locale)
        try await checkpoint(job, .fetchingCaptions, detail: nil)
        let downloaded = try await captionFile(in: workspace, input: input, tools: tools)
        let captions = try downloaded.map { try WebVTTCaptionParser.parse(String(contentsOf: $0.url, encoding: .utf8)) } ?? []
        try await checkpoint(job, .preparingSpeechModel, detail: nil)
        try await adapter.validate(modelID: selection.modelID)
        try await checkpoint(job, .preparingTranscript, detail: nil)
        let tracker = transcriptionProgressTracker
        let progressJobID = job.id
        tracker.set(0, for: progressJobID)
        defer { tracker.clear(progressJobID) }
        let checksum = try sha256(audio)
        let identity = ImportTranscriptCacheIdentity(sourceChecksum: checksum, engine: provenance.engine,
          model: provenance.model, locale: provenance.localeIdentifier, runtime: provenance.runtimeVersion, formatVersion: 2)
        let primaryFile = workspace.appendingPathComponent("primary-output.json")
        let primary: AudioTranscription
        if let cached = ImportTranscriptCache.load(AudioTranscription.self, from: primaryFile, identity: identity), !cached.words.isEmpty {
          primary = cached
        } else {
          primary = try await adapter.transcribe(audioURL: audio, modelID: selection.modelID, locale: locale,
            onProgress: { tracker.set(min(1, max(0, $0)) * 0.8, for: progressJobID) })
          try Task.checkCancellation()
          guard !primary.words.isEmpty else { throw TranscriptionAdapterError.emptyTranscript }
          try ImportTranscriptCache.save(primary, to: primaryFile, identity: identity)
        }
        tracker.set(0.8, for: progressJobID)
        var apple: AudioTranscription?
        var appleFailure: String?
        if input.compareWithApple != false, let audioTranscriber {
          do {
            let appleIdentity = ImportTranscriptCacheIdentity(sourceChecksum: checksum, engine: "Apple SpeechAnalyzer",
              model: "SpeechTranscriber", locale: locale,
              runtime: ProcessInfo.processInfo.operatingSystemVersionString, formatVersion: 1)
            let appleFile = workspace.appendingPathComponent("apple-output.json")
            if let cached = ImportTranscriptCache.load(AudioTranscription.self, from: appleFile, identity: appleIdentity), !cached.words.isEmpty {
              apple = cached
            } else {
              try await audioTranscriber.prepareForComparison(localeIdentifier: locale)
              let recognized = try await audioTranscriber.transcribe(audioURL: audio, localeIdentifier: locale,
                onProgress: { tracker.set(0.8 + min(1, max(0, $0)) * 0.2, for: progressJobID) })
              try Task.checkCancellation()
              guard !recognized.words.isEmpty else { throw TranscriptPreparationError.emptyApple }
              apple = recognized
              try ImportTranscriptCache.save(recognized, to: appleFile, identity: appleIdentity)
            }
          } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            appleFailure = error.localizedDescription
            logger.warning("Optional Apple comparison unavailable; retain primary ASR and mark review: \(error.localizedDescription, privacy: .public)")
          }
        }
        try Task.checkCancellation()
        try await checkpoint(job, .checkingTiming, detail: nil)
        let evidence = CombinedTranscriptArchive(version: 2, captionSource: downloaded?.source,
          captions: captions, whisperModel: nil, whisperWords: [], apple: apple,
          primary: primary, appleFailure: appleFailure)
        try JSONEncoder().encode(evidence).write(to: speechCaption, options: .atomic)
        preparedSegments = try CombinedTranscriptPreparation.prepare(
          primary: primary, apple: apple, captions: captions,
          captionSource: downloaded?.source, sampleRate: resolvedProbe.sampleRate,
          frameCount: resolvedProbe.frameCount)
        stagedCaption = speechCaption
        let captionAssetID = UUID()
        captionAsset = MediaAsset(id: captionAssetID, lessonID: job.lessonID, role: .caption,
          relativePath: "Media/Captions/\(captionAssetID.uuidString).json",
          checksum: try sha256(speechCaption), format: "json", sampleRate: nil,
          frameCount: nil, createdAt: Date())
      } else if let audioTranscriber {
        try await checkpoint(job, .preparingSpeechModel, detail: nil)
        try await audioTranscriber.prepare(localeIdentifier: input.localeIdentifier ?? "en-GB")
        try Task.checkCancellation()
        try await checkpoint(job, .preparingTranscript, detail: nil)
        let tracker = transcriptionProgressTracker
        let progressJobID = job.id
        tracker.set(0, for: progressJobID)
        defer { tracker.clear(progressJobID) }
        let transcript = try await audioTranscriber.transcribe(
          audioURL: audio, localeIdentifier: input.localeIdentifier ?? "en-GB",
          onProgress: { tracker.set($0, for: progressJobID) })
        try Task.checkCancellation()
        try await checkpoint(job, .checkingTiming, detail: nil)
        preparedSegments = try AudioFirstPreparation.prepareSegments(
          transcript: transcript, sampleRate: resolvedProbe.sampleRate,
          frameCount: resolvedProbe.frameCount)
      } else {
      if input.kind == .youtube {
        try await checkpoint(job, .fetchingCaptions, detail: nil)
        if let downloadedCaption = try await captionFile(
          in: workspace, input: input, tools: tools
        ) {
          let source = downloadedCaption.source
          let text = try String(contentsOf: downloadedCaption.url, encoding: .utf8)
          let cues = try WebVTTCaptionParser.parse(text)
          try await checkpoint(job, .preparingTranscript, detail: nil)
          let reviewedCues: [CaptionCue]
          let canVerifyCaptions: Bool
          if usesSpeechFallback {
            canVerifyCaptions = await MainActor.run {
              AppleSpeechCaptionTranscriber.isAvailableWithoutRequestingPermission()
            }
          } else {
            canVerifyCaptions = false
          }
          if canVerifyCaptions {
            do {
              let speechCues = try await AppleSpeechCaptionTranscriber.transcribe(audioURL: audio)
              reviewedCues = CaptionWordTimingAligner.enriching(
                captionCues: CaptionAudioMismatchDetector.markingReview(
                  captionCues: cues, against: speechCues),
                with: speechCues)
            } catch {
              logger.error(
                "Optional local caption verification was unavailable: \(error.localizedDescription, privacy: .public)"
              )
              reviewedCues = cues
            }
          } else {
            reviewedCues = cues
          }
          preparedSegments = try CaptionTranscriptBuilder.build(
            cues: reviewedCues, source: source, sampleRate: resolvedProbe.sampleRate,
            frameCount: resolvedProbe.frameCount)
          if FileManager.default.fileExists(atPath: vttCaption.path) {
            try FileManager.default.removeItem(at: vttCaption)
          }
          try FileManager.default.moveItem(at: downloadedCaption.url, to: vttCaption)
          stagedCaption = vttCaption
          let captionAssetID = UUID()
          captionAsset = MediaAsset(
            id: captionAssetID, lessonID: job.lessonID, role: .caption,
            relativePath: "Media/Captions/\(captionAssetID.uuidString).vtt",
            checksum: try sha256(vttCaption), format: "vtt", sampleRate: nil,
            frameCount: nil, createdAt: Date())
        }
      }
      if preparedSegments == nil, usesSpeechFallback {
        try await checkpoint(job, .preparingTranscript, detail: nil)
        let cues = try await AppleSpeechCaptionTranscriber.transcribe(audioURL: audio)
        preparedSegments = try CaptionTranscriptBuilder.build(
          cues: cues, source: .appleSpeech, sampleRate: resolvedProbe.sampleRate,
          frameCount: resolvedProbe.frameCount)
        try JSONEncoder().encode(cues).write(to: speechCaption, options: .atomic)
        stagedCaption = speechCaption
        let captionAssetID = UUID()
        captionAsset = MediaAsset(
          id: captionAssetID, lessonID: job.lessonID, role: .caption,
          relativePath: "Media/Captions/\(captionAssetID.uuidString).json",
          checksum: try sha256(speechCaption), format: "json", sampleRate: nil,
          frameCount: nil, createdAt: Date())
      }
      }

      if let segments = preparedSegments, let wordAligner {
        try await checkpoint(job, .checkingTiming, detail: nil)
        preparedSegments = try await AlignedTranscriptPreparation.prepare(segments, audioURL: audio,
          sampleRate: resolvedProbe.sampleRate, aligner: CachedWordAligner(underlying: wordAligner,
            directory: workspace.appendingPathComponent("WordAlignment"),
            version: "wav2vec2-22aad52d435eb6dbaf354bdad9b0da84ce7d6156-coreml-fp16-ctc-v2-sentence-onset"))
        try Task.checkCancellation()
      }

      try await checkpoint(job, .publishing, detail: nil)
      let sourceAssetID = UUID()
      let sourceAsset = MediaAsset(
        id: sourceAssetID, lessonID: job.lessonID, role: .sourceAudio,
        relativePath: "Media/SourceAudio/\(sourceAssetID.uuidString).m4a",
        checksum: try sha256(audio),
        format: "m4a", sampleRate: resolvedProbe.sampleRate, frameCount: resolvedProbe.frameCount,
        createdAt: Date())
      let thumbnailAsset: MediaAsset?
      if FileManager.default.fileExists(atPath: thumbnail.path) {
        let thumbnailAssetID = UUID()
        thumbnailAsset = MediaAsset(
          id: thumbnailAssetID, lessonID: job.lessonID, role: .thumbnail,
          relativePath: "Media/Thumbnails/\(thumbnailAssetID.uuidString).jpg",
          checksum: try sha256(thumbnail),
          format: "jpg", sampleRate: nil, frameCount: nil, createdAt: Date())
      } else {
        thumbnailAsset = nil
      }
      let manifest = CommitManifest(
        lessonID: job.lessonID, expectedGeneration: job.expectedGeneration,
        title: resolvedTitle, author: resolvedAuthor,
        assets: [sourceAsset] + (thumbnailAsset.map { [$0] } ?? [])
          + (captionAsset.map { [$0] } ?? []),
        segments: preparedSegments,
        annotations: try await preparedIPAAnnotations(for: preparedSegments))
      try Data(try json(manifest).utf8).write(to: manifestURL, options: .atomic)
      let finalAudio = paths.root.appendingPathComponent(sourceAsset.relativePath)
      try FileManager.default.createDirectory(
        at: finalAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: audio, to: finalAudio)
      if let thumbnailAsset {
        let finalThumbnail = paths.root.appendingPathComponent(thumbnailAsset.relativePath)
        try FileManager.default.createDirectory(
          at: finalThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: thumbnail, to: finalThumbnail)
      }
      if let captionAsset, let stagedCaption {
        let finalCaption = paths.root.appendingPathComponent(captionAsset.relativePath)
        try FileManager.default.createDirectory(
          at: finalCaption.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagedCaption, to: finalCaption)
      }
      let ready = ImportCheckpoint(
        phase: .ready, workspaceRelativePath: manifest.workspaceRelativePath,
        manifestRelativePath: "Cache/ImportJobs/\(job.id.uuidString)/commit-manifest.json",
        detail: nil, updatedAt: Date())
      try await publish(manifest: manifest, job: job, checkpointJSON: try json(ready))
      runtimeFailures[job.id] = nil
      removeBestEffort(workspace, operation: "Remove completed import workspace")
    } catch SubprocessError.cancelled {
      await recordTerminal(job, phase: .cancelled, failure: ProductionImportError.cancelled)
    } catch {
      await recordTerminal(job, phase: Task.isCancelled || error is CancellationError ? .cancelled : .failed, failure: error)
    }
    if tasks[job.id]?.runToken == job.runToken { tasks[job.id] = nil }
  }

  private func decodeInput(_ stored: StoredImportJob) throws -> StoredInput {
    do {
      return try JSONDecoder().decode(StoredInput.self, from: Data(stored.inputJSON.utf8))
    } catch {
      throw ProductionImportError.recoveryRequired("Stored import input is invalid.")
    }
  }

  private func publish(
    manifest: CommitManifest, job: ProductionImportJob, checkpointJSON: String
  ) async throws {
    try Task.checkCancellation()
    if let segments = manifest.segments, !segments.isEmpty {
      try await database.publishPreparedLesson(
        lessonID: job.lessonID, expectedGeneration: job.expectedGeneration, jobID: job.id,
        runToken: job.runToken, title: manifest.title, author: manifest.author,
        assets: manifest.assets, segments: segments, annotations: manifest.annotations ?? [],
        checkpointJSON: checkpointJSON)
    } else {
      try await database.publishImportedAssets(
        lessonID: job.lessonID, expectedGeneration: job.expectedGeneration, jobID: job.id,
        runToken: job.runToken, title: manifest.title, author: manifest.author,
        assets: manifest.assets, checkpointJSON: checkpointJSON)
    }
  }

  private func preparedIPAAnnotations(
    for segments: [PreparedLessonSegment]?
  ) async throws -> [PreparedLessonAnnotation]? {
    guard let segments, !segments.isEmpty, let ipaDictionary else { return nil }
    var fallback: IPAFallback?
    if let g2p = ipaG2P {
      fallback = { word, accent in try await g2p.pronunciation(word, accent: accent) }
    }
    return try await IPAAnnotationBuilder.build(segments: segments, dictionary: ipaDictionary, fallback: fallback)
  }

  private func captionFile(
    in workspace: URL, input: StoredInput, tools: BundledImportToolchain.Tools
  ) async throws -> DownloadedCaption? {
    guard input.kind == .youtube else { return nil }
    if let authorCaption = vttFile(in: workspace) {
      return DownloadedCaption(url: authorCaption, source: .creatorCaption)
    }
    // Keep automatic captions separate so a retry cannot relabel them as creator captions.
    let automaticFolder = workspace.appendingPathComponent("automatic-captions", isDirectory: true)
    try FileManager.default.createDirectory(at: automaticFolder, withIntermediateDirectories: true)
    if let cached = vttFile(in: automaticFolder) {
      return DownloadedCaption(url: cached, source: .automaticCaption)
    }
    _ = try await runner.run(
      executable: tools.ytDLP,
      arguments: [
        "--no-config", "--no-update", "--no-playlist", "--js-runtimes", "quickjs:\(tools.qjs.path)",
        "--skip-download", "--write-auto-subs", "--sub-langs", "en.*", "--sub-format", "vtt",
        "-o", "\(automaticFolder.path)/%(id)s.%(ext)s", input.sourceURL.absoluteString,
      ], currentDirectory: workspace)
    guard let automaticCaption = vttFile(in: automaticFolder) else { return nil }
    return DownloadedCaption(url: automaticCaption, source: .automaticCaption)
  }

  private func vttFile(in workspace: URL) -> URL? {
    (try? FileManager.default.contentsOfDirectory(
      at: workspace, includingPropertiesForKeys: [.isRegularFileKey]))?
      .filter { $0.pathExtension.lowercased() == "vtt" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .first
  }

  private func recordTerminal(
    _ job: ProductionImportJob, phase: ProductionImportPhase, failure: any Error
  ) async {
    guard tasks[job.id]?.runToken == job.runToken else { return }
    let displayed: ProductionImportError
    if phase == .cancelled {
      displayed = .cancelled
    } else if let failure = failure as? ProductionImportError {
      displayed = failure
    } else if let failure = failure as? SubprocessError {
      displayed = .subprocess(failure)
    } else {
      displayed = .recoveryRequired(failure.localizedDescription)
    }
    do {
      try await checkpoint(job, phase, detail: displayed.localizedDescription)
    } catch {
      runtimeFailures[job.id] = ProductionImportJob(
        id: job.id, lessonID: job.lessonID, title: job.title, phase: phase,
        runToken: job.runToken, expectedGeneration: job.expectedGeneration, error: displayed,
        createdAt: job.createdAt, updatedAt: Date())
      logger.error("Persist terminal import state: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func removeBestEffort(_ url: URL, operation: String) {
    do { try FileManager.default.removeItem(at: url) } catch {
      logger.error(
        "\(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  private func checkpoint(
    _ job: ProductionImportJob, _ phase: ProductionImportPhase, detail: String?
  ) async throws {
    if !phase.isTerminal { try Task.checkCancellation() }
    let checkpoint = ImportCheckpoint(
      phase: phase, workspaceRelativePath: "Cache/ImportJobs/\(job.id.uuidString)",
      manifestRelativePath: nil, detail: detail, updatedAt: Date())
    try await database.checkpointImportJob(
      id: job.id, expectedGeneration: job.expectedGeneration, runToken: job.runToken,
      status: phase == .cancelled ? "cancelled" : phase == .failed ? "failed" : "running",
      checkpointJSON: try json(checkpoint))
  }

  private func resolveIdentity(for request: ProductionImportRequest) async throws -> StoredInput {
    switch request {
    case .youtube(let url, let titleOverride):
      guard let id = Self.youtubeID(url) else { throw ProductionImportError.invalidYouTubeURL }
      return StoredInput(
        kind: .youtube, provider: "youtube", externalID: id, sourceURL: url,
        title: titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? id,
        lessonID: nil, securityScoped: false)
    case .localAudio(let url, let scoped, let titleOverride):
      let access = scoped ? url.startAccessingSecurityScopedResource() : true
      defer { if scoped && access { url.stopAccessingSecurityScopedResource() } }
      guard access, FileManager.default.isReadableFile(atPath: url.path) else {
        throw ProductionImportError.inaccessibleLocalAudio
      }
      return StoredInput(
        kind: .localAudio, provider: "local", externalID: try sha256(url), sourceURL: url,
        title: titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
          ?? url.deletingPathExtension().lastPathComponent,
        lessonID: nil, securityScoped: scoped)
    }
  }

  private static let downloadedAudioExtensions: Set<String> = [
    "webm", "m4a", "mp4", "opus", "ogg", "oga", "mka", "mp3", "aac", "flac", "wav",
  ]

  /// Integrated loudness of `source`, or `nil` when ffmpeg reports nothing usable.
  private func measureLoudness(_ source: URL, tools: BundledImportToolchain.Tools, in workspace: URL) async throws -> Double? {
    let output = try await runner.run(
      executable: tools.ffmpeg, arguments: SourceLoudness.measurementArguments(source: source),
      currentDirectory: workspace)
    return SourceLoudness.integratedLoudness(in: output.standardError)
  }

  /// Writes the stored AAC copy of `source`, levelled to `SourceLoudness.targetLUFS`.
  private func writeLevelledSource(
    from source: URL, to destination: URL, tools: BundledImportToolchain.Tools, in workspace: URL,
    minimumFrames: Int? = nil
  ) async throws -> Double {
    let gain = try await measureLoudness(source, tools: tools, in: workspace).map(SourceLoudness.gainDB) ?? 0
    _ = try await runner.run(
      executable: tools.ffmpeg,
      arguments: SourceLoudness.encodeArguments(
        source: source, destination: destination, gainDB: gain, minimumFrames: minimumFrames),
      currentDirectory: workspace)
    return gain
  }

  /// Levels source audio imported before levelling existed. Each file goes
  /// through the same chain a new import uses, is kept at least as long as
  /// before so stored sentence timing stays valid, and its media row is
  /// updated. With `apply: false` nothing is written; the reports say what would
  /// change.
  func levelStoredSourceAudio(apply: Bool) async throws -> [SourceLevelReport] {
    let tools = try toolchain.resolve()
    var reports: [SourceLevelReport] = []
    for asset in try await database.sourceAudioAssets() {
      let url = paths.root.appendingPathComponent(asset.relativePath)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let workspace = paths.importWorkspace(for: UUID())
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      defer { removeBestEffort(workspace, operation: "Remove levelling workspace") }
      let measured = try await measureLoudness(url, tools: tools, in: workspace)
      let gain = measured.map(SourceLoudness.gainDB) ?? 0
      var applied = false
      if apply, gain != 0 {
        let levelled = workspace.appendingPathComponent("levelled.m4a")
        _ = try await runner.run(
          executable: tools.ffmpeg,
          arguments: SourceLoudness.encodeArguments(
            source: url, destination: levelled, gainDB: gain, minimumFrames: asset.frameCount),
          currentDirectory: workspace)
        let probe = try await probe(levelled, with: tools.ffprobe, in: workspace)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: levelled)
        try await database.updateSourceAudioAsset(
          id: asset.id, checksum: try sha256(url), sampleRate: probe.sampleRate, frameCount: probe.frameCount)
        applied = true
      }
      reports.append(SourceLevelReport(
        relativePath: asset.relativePath, measuredLUFS: measured, gainDB: gain, applied: applied))
    }
    return reports
  }

  private func probe(_ audio: URL, with ffprobe: URL, in workspace: URL) async throws -> AudioProbe
  {
    let output = try await runner.run(
      executable: ffprobe,
      arguments: [
        "-v", "error", "-show_entries",
        "stream=codec_type,sample_rate,duration_ts,time_base", "-of", "json", audio.path,
      ], currentDirectory: workspace)
    let decoded = try JSONDecoder().decode(
      ProbeDocument.self, from: Data(output.standardOutput.utf8))
    guard decoded.streams.count == 1, let stream = decoded.streams.first,
      stream.codecType == "audio", let rate = Int(stream.sampleRate), rate > 0,
      let ticks = Double(stream.durationTS), let base = Self.timeBase(stream.timeBase)
    else {
      throw ProductionImportError.unsupportedMedia(
        "ffprobe did not report exactly one audio stream with a duration")
    }
    let frames = Int((ticks * base * Double(rate)).rounded())
    guard frames > 0 else { throw ProductionImportError.unsupportedMedia("audio has no frames") }
    return AudioProbe(sampleRate: rate, frameCount: frames)
  }

  private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private static func youtubeID(_ url: URL) -> String? {
    YouTubeLink.videoID(url.absoluteString)
  }
  private static func timeBase(_ text: String) -> Double? {
    let parts = text.split(separator: "/")
    guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 else {
      return nil
    }
    return n / d
  }
}

private enum InputKind: String, Codable, Sendable { case youtube, localAudio }
private struct StoredInput: Codable, Sendable {
  let kind: InputKind
  let provider: String
  let externalID: String
  let sourceURL: URL
  let title: String
  var lessonID: UUID?
  let securityScoped: Bool?
  var localeIdentifier: String?
  var transcriptionSelection: TranscriptionSelection?
  var compareWithApple: Bool?
  var previousTranscriptionSelections: [TranscriptionSelection]?
}
private struct YouTubeMetadata: Decodable {
  let title: String
  let uploader: String?
  let channel: String?
}
private struct DownloadedCaption {
  let url: URL
  let source: TranscriptSource
}
private struct CommitManifest: Codable {
  let lessonID: UUID
  let expectedGeneration: Int
  let title: String
  let author: String?
  let assets: [MediaAsset]
  let segments: [PreparedLessonSegment]?
  let annotations: [PreparedLessonAnnotation]?
  var workspaceRelativePath: String { "Cache/ImportJobs" }
}
private struct AudioProbe {
  let sampleRate: Int
  let frameCount: Int
}
private struct ProbeDocument: Decodable { let streams: [ProbeStream] }
private struct ProbeStream: Decodable {
  let codecType: String
  let sampleRate: String
  let durationTS: String
  let timeBase: String

  enum CodingKeys: String, CodingKey {
    case codecType = "codec_type"
    case sampleRate = "sample_rate"
    case durationTS = "duration_ts"
    case timeBase = "time_base"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    codecType = try values.decode(String.self, forKey: .codecType)
    sampleRate = try Self.text(in: values, forKey: .sampleRate)
    durationTS = try Self.text(in: values, forKey: .durationTS)
    timeBase = try values.decode(String.self, forKey: .timeBase)
  }

  private static func text(
    in values: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) throws -> String {
    if let text = try? values.decode(String.self, forKey: key) { return text }
    if let integer = try? values.decode(Int64.self, forKey: key) { return String(integer) }
    return String(try values.decode(Double.self, forKey: key))
  }
}
private struct DeletionManifest: Codable {
  let lessonID: UUID
  let expectedGeneration: Int
  let assets: [MediaAsset]
}
extension String { fileprivate var nonEmpty: String? { isEmpty ? nil : self } }
