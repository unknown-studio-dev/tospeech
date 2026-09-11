import CryptoKit
import Foundation
import OSLog

actor ProductionImportService {
  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let toolchain: BundledImportToolchain
  private let runner: SubprocessRunner
  private let removeManagedItem: @Sendable (URL) throws -> Void
  private let usesSpeechFallback: Bool
  private let ipaDictionary: OfflineIPADictionary?
  private let logger = Logger(
    subsystem: "com.unknownstudio.EchoLab", category: "ProductionImport")
  private struct ActiveImport {
    let lessonID: UUID
    let runToken: UUID
    let task: Task<Void, Never>
  }
  private var tasks: [UUID: ActiveImport] = [:]
  private var runtimeFailures: [UUID: ProductionImportJob] = [:]

  init(
    database: ProductionDatabase, paths: BackendPaths, toolchain: BundledImportToolchain = .init(),
    runner: SubprocessRunner = .init(),
    usesSpeechFallback: Bool = true,
    ipaDictionary: OfflineIPADictionary? = nil,
    removeManagedItem: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) {
    self.database = database
    self.paths = paths
    self.toolchain = toolchain
    self.runner = runner
    self.usesSpeechFallback = usesSpeechFallback
    self.ipaDictionary = ipaDictionary ?? (try? OfflineIPADictionary.bundled())
    self.removeManagedItem = removeManagedItem
  }

  func submit(_ request: ProductionImportRequest) async throws -> ProductionImportJob {
    let tools: BundledImportToolchain.Tools
    do { tools = try toolchain.resolve() } catch let error as BundledImportToolchainError {
      throw ProductionImportError.toolchain(error)
    }
    try paths.prepare()
    var identity = try await resolveIdentity(for: request)
    let lessonID = UUID()
    let jobID = UUID()
    let runToken = UUID()
    let createdAt = Date()
    identity.lessonID = lessonID
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

  func retry(jobID: UUID) async throws {
    let stored = try await database.unfinishedImportJobs().first(where: { $0.id == jobID })
    guard let stored else {
      throw ProductionImportError.recoveryRequired("Import job no longer exists.")
    }
    let input = try JSONDecoder().decode(StoredInput.self, from: Data(stored.inputJSON.utf8))
    guard let lessonID = input.lessonID else {
      throw ProductionImportError.recoveryRequired("Import job has no lesson identity.")
    }
    let tools = try toolchain.resolve()
    tasks[jobID]?.task.cancel()
    runtimeFailures[jobID] = nil
    let runToken = try await database.beginImportRetry(
      id: stored.id, expectedGeneration: stored.expectedGeneration)
    let job = ProductionImportJob(
      id: stored.id, lessonID: lessonID, title: input.title, phase: .resolving,
      runToken: runToken, expectedGeneration: stored.expectedGeneration, error: nil,
      createdAt: Date(), updatedAt: Date())
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(job: job, input: input, tools: tools)
    }
    tasks[jobID] = ActiveImport(lessonID: lessonID, runToken: runToken, task: task)
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
    }
    try await database.completeLessonDeletion(
      lessonID: manifest.lessonID, expectedGeneration: manifest.expectedGeneration)
    removeBestEffort(manifestURL, operation: "Remove completed deletion intent")
  }

  private func run(
    job: ProductionImportJob, input: StoredInput, tools: BundledImportToolchain.Tools
  ) async {
    do {
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
              "-f", "bestaudio", "--extract-audio", "--audio-format", "m4a", "--ffmpeg-location",
              tools.ffmpeg.deletingLastPathComponent().path,
              "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
              "--write-subs", "--sub-langs", "en.*", "--sub-format", "vtt",
              "-o", "\(workspace.path)/%(id)s.%(ext)s", input.sourceURL.absoluteString,
            ], currentDirectory: workspace)
          let candidates = try FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil)
          guard let downloaded = candidates.first(where: { $0.pathExtension.lowercased() == "m4a" })
          else {
            throw ProductionImportError.unsupportedMedia("yt-dlp did not produce an M4A source")
          }
          guard let image = candidates.first(where: { $0.pathExtension.lowercased() == "jpg" })
          else {
            throw ProductionImportError.unsupportedMedia("yt-dlp did not produce a JPEG thumbnail")
          }
          try FileManager.default.moveItem(at: downloaded, to: audio)
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
          _ = try await runner.run(
            executable: tools.ffmpeg,
            arguments: [
              "-y", "-i", input.sourceURL.path, "-vn", "-c:a", "aac", audio.path,
            ], currentDirectory: workspace)
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
      await recordTerminal(job, phase: .failed, failure: error)
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
    return try await IPAAnnotationBuilder.build(segments: segments, dictionary: ipaDictionary)
  }

  private func captionFile(
    in workspace: URL, input: StoredInput, tools: BundledImportToolchain.Tools
  ) async throws -> DownloadedCaption? {
    if let authorCaption = vttFile(in: workspace) {
      return DownloadedCaption(url: authorCaption, source: .creatorCaption)
    }
    guard input.kind == .youtube else { return nil }
    _ = try await runner.run(
      executable: tools.ytDLP,
      arguments: [
        "--no-config", "--no-update", "--no-playlist", "--js-runtimes", "quickjs:\(tools.qjs.path)",
        "--skip-download", "--write-auto-subs", "--sub-langs", "en.*", "--sub-format", "vtt",
        "-o", "\(workspace.path)/%(id)s.%(ext)s", input.sourceURL.absoluteString,
      ], currentDirectory: workspace)
    guard let automaticCaption = vttFile(in: workspace) else { return nil }
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
