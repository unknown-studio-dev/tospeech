import AVFoundation
import AVFoundation
import CryptoKit
import Foundation
import OSLog

@MainActor
final class ProductionPracticeService {
  var enhanceRecordings = true
  /// Which `sentence:<language>` annotation prepared sentences expose as their translation.
  var translationLanguage: TranslationLanguage = .legacyDefault
  private var storedPlayer: ProductionAudioPlayer?
  private var storedRecorder: ProductionAudioRecorder?
  var player: ProductionAudioPlayer {
    if let storedPlayer { return storedPlayer }
    let value = ProductionAudioPlayer()
    storedPlayer = value
    return value
  }

  func waveformSamples(
    audioURL: URL, sampleRate: Int, duration: TimeInterval, count: Int = 800
  ) async throws -> [Double] {
    guard sampleRate > 0, duration > 0, count > 0 else {
      throw ProductionPracticeError.invalidPlaybackRange
    }
    return try await Task.detached(priority: .utility) {
      let file = try AVAudioFile(forReading: audioURL)
      let totalFrames = min(file.length, AVAudioFramePosition(duration * Double(sampleRate)))
      guard totalFrames > 0 else { throw ProductionPracticeError.sourceUnavailable }
      file.framePosition = 0
      var peaks = Array(repeating: Float.zero, count: count)
      let capacity: AVAudioFrameCount = 8_192
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
      else { throw ProductionPracticeError.sourceUnavailable }
      var consumed: AVAudioFramePosition = 0
      while consumed < totalFrames {
        let requested = AVAudioFrameCount(min(AVAudioFramePosition(capacity), totalFrames - consumed))
        try file.read(into: buffer, frameCount: requested)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        let channelCount = Int(buffer.format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
          var peak = Float.zero
          for channel in 0..<channelCount { peak = max(peak, abs(channels[channel][frame])) }
          let absolute = consumed + AVAudioFramePosition(frame)
          let index = min(count - 1, Int(absolute * AVAudioFramePosition(count) / totalFrames))
          peaks[index] = max(peaks[index], peak)
        }
        consumed += AVAudioFramePosition(buffer.frameLength)
      }
      let maximum = max(peaks.max() ?? 0, 0.000_1)
      return peaks.map { Double($0 / maximum) }
    }.value
  }
  var recorder: ProductionAudioRecorder {
    if let storedRecorder { return storedRecorder }
    let value = ProductionAudioRecorder()
    storedRecorder = value
    return value
  }

  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let logger = Logger(
    subsystem: "com.unknownstudio.tospeech", category: "ProductionPractice")
  private var sessions: [UUID: UUID] = [:]
  private var listenedRevisionID: UUID?
  private var activeCapture: ProductionCaptureHandle?
  private var pendingManifest: TakeCommitManifest?

  init(
    database: ProductionDatabase, paths: BackendPaths,
    player: ProductionAudioPlayer? = nil, recorder: ProductionAudioRecorder? = nil
  ) {
    self.database = database
    self.paths = paths
    storedPlayer = player
    storedRecorder = recorder
  }

  func target(lessonID: UUID) async throws -> ProductionPracticeTarget? {
    try await database.practiceTarget(lessonID: lessonID, paths: paths)
  }

  func targets(lessonID: UUID) async throws -> [ProductionPracticeTarget] {
    try await database.practiceTargets(lessonID: lessonID, paths: paths)
  }

  func preparedSentences(lessonID: UUID) async throws -> [ProductionPreparedSentence] {
    try await database.preparedPracticeSentences(lessonID: lessonID, paths: paths)
      .map(stampingTranslationLanguage)
  }

  func stampingTranslationLanguage(_ sentence: ProductionPreparedSentence) -> ProductionPreparedSentence {
    var value = sentence
    value.translationLanguage = translationLanguage
    return value
  }

  func takes(lessonID: UUID) async throws -> [ProductionStoredTake] {
    try await database.practiceTakes(lessonID: lessonID)
  }

  func savedTakeSentences(lessonID: UUID) async throws -> [UUID: ProductionPreparedSentence] {
    try await database.savedTakeSentences(lessonID: lessonID, paths: paths)
      .mapValues(stampingTranslationLanguage)
  }

  func pronunciationJobs(lessonID: UUID) async throws -> [PronunciationJob] {
    try await database.pronunciationJobs(lessonID: lessonID)
  }

  func recordingByteCounts(_ takes: [ProductionStoredTake]) async -> [UUID: Int64] {
    let directory = paths.finalTakes
    return await Task.detached(priority: .utility) {
      Dictionary(uniqueKeysWithValues: takes.map { take in
        let url = directory.appendingPathComponent("\(take.id.uuidString).caf")
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return (take.id, Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0))
      })
    }.value
  }

  /// Deletes only committed take audio and its dependent analysis history. The
  /// take is hidden in SQLite first, so a relaunch can safely finish file cleanup.
  @discardableResult
  func deleteRecordings(ids: Set<UUID>, lessonID: UUID) async throws -> Int64 {
    guard !ids.isEmpty else { return 0 }
    storedPlayer?.stop()
    try paths.prepare()
    let records = try await database.markPracticeTakesForDeletion(ids: ids, lessonID: lessonID)
    let bytes = try removeDiscardedTakeFiles(records)
    try await database.purgeDiscardedPracticeTakes(records)
    return bytes
  }

  func publishTimingRevision(_ draft: SegmentTimingRevisionDraft) async throws -> StoredTimingRevision {
    try await database.publishTimingRevision(draft)
  }

  func removeTranscriptWord(segmentID: UUID, expectedRevisionID: UUID, tokenID: String) async throws -> StoredTimingRevision {
    try await database.publishTranscriptRevision(
      segmentID: segmentID, expectedRevisionID: expectedRevisionID, removingTokenID: tokenID)
  }

  /// A manual translation always targets the language the learner is reading in.
  func storeTranslationOverride(revisionID: UUID, text: String) async throws {
    guard !translationLanguage.isNone else { return }
    let value = SentenceTranslationValue(
      text: text, sourceLanguage: "en", targetLanguage: translationLanguage.id)
    try await database.storeAnnotationOverride(
      revisionID: revisionID, kind: .translation, lookupKey: translationLanguage.lookupKey,
      source: "manual", value: try JSONEncoder().encode(value))
  }

  /// An observed word interval is playable even when flagged for review;
  /// missing/invalid intervals use sentence context. This never marks a sentence listened,
  /// so recording still requires a full source listen.
  func preview(
    _ token: TranscriptWordToken, in target: ProductionPracticeTarget, speed: Double = 1
  ) throws {
    try target.validate()
    let range = ProductionWordTiming.previewRange(for: token, in: target)
    try player.play(url: target.audioURL, startFrame: range.lowerBound, endFrame: range.upperBound, speed: speed) {}
  }

  func preview(_ span: AudioSpan, in target: ProductionPracticeTarget, speed: Double = 1) throws {
    try target.validate()
    let start = Int((span.start * Double(target.sampleRate)).rounded())
    let end = Int((span.end * Double(target.sampleRate)).rounded())
    guard start >= 0, end > start else { throw ProductionPracticeError.invalidPlaybackRange }
    try player.play(url: target.audioURL, startFrame: start, endFrame: end, speed: speed) {}
  }

  /// Takes are replayed only from the managed final-take directory. A stored
  /// database path is never treated as an arbitrary playback URL.
  func reviewAudioAsset(_ take: ProductionStoredTake) -> ReviewAudioAsset? {
    guard take.status == "ready", let sampleRate = take.sampleRate, sampleRate > 0,
      let frames = take.frameCount, frames > 0 else { return nil }
    return .init(id: take.id.uuidString, url: paths.finalTakes.appendingPathComponent("\(take.id.uuidString).caf"),
      sampleRate: sampleRate, startFrame: 0, endFrame: frames)
  }

  func playTake(_ take: ProductionStoredTake, span: AudioSpan? = nil) throws {
    guard take.status == "ready", let sampleRate = take.sampleRate,
      let frameCount = take.frameCount, sampleRate > 0, frameCount > 0
    else { throw ProductionPracticeError.sourceUnavailable }
    let url = paths.finalTakes.appendingPathComponent("\(take.id.uuidString).caf")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ProductionPracticeError.sourceUnavailable
    }
    let start = span.map { Int((max(0, $0.start) * Double(sampleRate)).rounded()) } ?? 0
    let end = span.map { min(frameCount, Int(($0.end * Double(sampleRate)).rounded())) } ?? frameCount
    try player.play(url: url, startFrame: start, endFrame: end, speed: 1,
      levelRecording: enhanceRecordings, enhanceRecording: enhanceRecordings) {}
  }

  func compare(_ target: ProductionPracticeTarget, with take: ProductionStoredTake,
    onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) throws {
    try target.validate()
    try player.play(
      url: target.audioURL, startFrame: target.startFrame,
      endFrame: target.playbackEndFrame, speed: take.sourceSpeed
    ) { [weak self] in
      do { try self?.playTake(take) }
      catch {
        self?.logger.error(
          "Could not play the saved half of A/B comparison: \(error.localizedDescription, privacy: .public)")
        onFailure(error.localizedDescription)
      }
    }
  }

  func compareTogether(_ target: ProductionPracticeTarget, with take: ProductionStoredTake) throws {
    try target.validate()
    guard activeCapture == nil, pendingManifest == nil, take.status == "ready",
      take.segmentRevisionID == target.segmentRevisionID,
      let count = take.frameCount, count > 0, let rate = take.sampleRate, rate > 0
    else { throw ProductionPracticeError.sourceUnavailable }
    let url = paths.finalTakes.appendingPathComponent("\(take.id.uuidString).caf")
    try player.playTogether(sourceURL: target.audioURL, sourceFrames: target.startFrame..<target.playbackEndFrame,
      takeURL: url, takeFrames: 0..<count,
      levelRecording: enhanceRecordings, enhanceRecording: enhanceRecordings)
  }

  func compareDetail(_ target: ProductionPracticeTarget, take: ProductionStoredTake,
    sourceSpan: AudioSpan, takeSpan: AudioSpan,
    onFailure: @escaping @MainActor @Sendable (String) -> Void
  ) throws {
    try target.validate()
    let sourceFrames = try PlaybackFrameRange.resolve(sourceSpan, sampleRate: target.sampleRate,
      bounds: target.startFrame..<target.playbackEndFrame)
    guard let takeRate = take.sampleRate, let takeCount = take.frameCount, takeCount > 0
    else { throw ProductionPracticeError.sourceUnavailable }
    // The recording has its own alignment, sample rate and duration. Never
    // rescale its interval to the reference sentence's duration or frame bounds.
    _ = try PlaybackFrameRange.resolve(takeSpan, sampleRate: takeRate, bounds: 0..<takeCount)
    try player.play(url: target.audioURL,
      startFrame: sourceFrames.lowerBound,
      endFrame: sourceFrames.upperBound, speed: 1) { [weak self] in
        do { try self?.playTake(take, span: takeSpan) }
        catch { onFailure(error.localizedDescription) }
      }
  }

  func play(
    _ target: ProductionPracticeTarget, speed: Double,
    onCompletion: @escaping @MainActor @Sendable () -> Void = {}
  ) throws {
    try target.validate()
    listenedRevisionID = nil
    try player.play(
      url: target.audioURL, startFrame: target.startFrame,
      endFrame: target.playbackEndFrame, speed: speed
    ) { [weak self] in
      self?.listenedRevisionID = target.segmentRevisionID
      onCompletion()
    }
  }

  func pausePlayback() { player.pause() }
  func resumePlayback() throws { try player.resume() }
  func updatePlaybackSpeed(_ speed: Double) throws { try player.updateSpeed(speed) }
  func stopPlayback() { storedPlayer?.stop() }

  func startCapture(
    target: ProductionPracticeTarget, sourceSpeed: Double, policy: ProductionCapturePolicy,
    requiresCompletedListen: Bool = true
  ) async throws -> ProductionCaptureHandle {
    guard !requiresCompletedListen || listenedRevisionID == target.segmentRevisionID else {
      throw ProductionPracticeError.sourceMustBeListenedFirst
    }
    guard activeCapture == nil, pendingManifest == nil else {
      throw ProductionPracticeError.recoveryRequired("Save or discard the current take first.")
    }
    guard ProductionAudioRecorder.authorization == .granted else {
      throw ProductionPracticeError.microphoneDenied
    }
    storedPlayer?.stop()
    try paths.prepare()
    let targetJSON = String(
      decoding: try JSONEncoder().encode(target.snapshot), as: UTF8.self)
    let identities: (sessionID: UUID, roundID: UUID, takeID: UUID)
    do {
      identities = try await database.beginPracticeCapture(
        target: target, sessionID: sessions[target.lessonID],
        sourceSpeed: sourceSpeed, targetJSON: targetJSON)
    } catch {
      throw ProductionPracticeError.persistence(error.localizedDescription)
    }
    sessions[target.lessonID] = identities.sessionID
    let handle = ProductionCaptureHandle(
      sessionID: identities.sessionID, roundID: identities.roundID,
      takeID: identities.takeID, target: target, sourceSpeed: sourceSpeed,
      stagingURL: paths.takeStaging.appendingPathComponent("\(identities.takeID.uuidString).caf"),
      finalURL: paths.finalTakes.appendingPathComponent("\(identities.takeID.uuidString).caf"),
      manifestURL: paths.takeStaging.appendingPathComponent("\(identities.takeID.uuidString).json"))
    do {
      try recorder.start(to: handle.stagingURL, policy: policy)
      activeCapture = handle
      return handle
    } catch {
      do { try await database.discardPracticeTake(id: handle.takeID) }
      catch { logger.error("Discard failed capture row: \(error.localizedDescription, privacy: .public)") }
      removeBestEffort(handle.stagingURL)
      throw error
    }
  }

  func finishCapture(
    policy: ProductionCapturePolicy, interrupted: Bool = false, reachedDurationLimit: Bool = false
  ) async throws -> ProductionStoredTake {
    guard let handle = activeCapture else { throw ProductionPracticeError.captureNotRunning }
    let artifact = try recorder.finish()
    let classified = artifact.outcome(policy: policy, interrupted: interrupted)
    // With a fixed recording window reaching the limit is the normal end, not an early stop.
    let outcome: CaptureOutcome =
      classified == .complete && reachedDurationLimit && !policy.fixedWindow ? .earlyStop : classified
    // The window is now fixed to the source sentence length, so takes keep their full timing —
    // no silence trimming. Passing a nil trim policy keeps the retained take exactly as recorded.
    let manifest = TakeCommitManifest(
      handle: handle, assetID: UUID(), checksum: try sha256(artifact.url),
      sampleRate: artifact.sampleRate, frameCount: artifact.frameCount,
      outcome: outcome, trimPolicy: nil)
    pendingManifest = manifest
    do {
      let result = try await commit(manifest)
      activeCapture = nil
      pendingManifest = nil
      listenedRevisionID = nil
      return result
    } catch {
      throw ProductionPracticeError.persistence(error.localizedDescription)
    }
  }

  func retrySave() async throws -> ProductionStoredTake {
    guard let manifest = pendingManifest else {
      throw ProductionPracticeError.recoveryRequired("No retained take is available.")
    }
    let result = try await commit(manifest)
    activeCapture = nil
    pendingManifest = nil
    listenedRevisionID = nil
    return result
  }

  func discardPending() async throws {
    guard let handle = activeCapture ?? pendingManifest?.handle else { return }
    storedRecorder?.stopWithoutArtifact()
    try await database.discardPracticeTake(id: handle.takeID)
    for url in [handle.stagingURL, handle.finalURL, handle.manifestURL,
      RecordingSilenceTrimmer.receiptURL(for: handle.finalURL)]
    where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    activeCapture = nil
    pendingManifest = nil
    listenedRevisionID = nil
  }

  func recoverPendingTakes() async throws {
    try paths.prepare()
    let discarded = try await database.discardedPracticeTakes()
    if !discarded.isEmpty {
      _ = try removeDiscardedTakeFiles(discarded)
      try await database.purgeDiscardedPracticeTakes(discarded)
    }
    let manifests = try FileManager.default.contentsOfDirectory(
      at: paths.takeStaging, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    for url in manifests {
      let manifest = try JSONDecoder().decode(
        TakeCommitManifest.self, from: Data(contentsOf: url))
      _ = try await commit(manifest)
    }
  }

  private func commit(_ manifest: TakeCommitManifest) async throws -> ProductionStoredTake {
    let handle = manifest.handle
    try validate(handle)
    if let existing = try await database.practiceTakes(lessonID: handle.target.lessonID)
      .first(where: { $0.id == handle.takeID && $0.status == "ready" })
    {
      removeBestEffort(handle.stagingURL)
      removeBestEffort(handle.manifestURL)
      return existing
    }

    try await database.markTakeFinalizing(id: handle.takeID)
    if !FileManager.default.fileExists(atPath: handle.manifestURL.path) {
      try JSONEncoder().encode(manifest).write(to: handle.manifestURL, options: .atomic)
    }
    let finalChecksum: String
    let finalFrames: Int
    if manifest.trimPolicy != nil {
      let trimmed = try await Task.detached(priority: .userInitiated) {
        try RecordingSilenceTrimmer.publish(manifest)
      }.value
      finalChecksum = trimmed.checksum
      finalFrames = trimmed.plan.frameCount
    } else {
      if FileManager.default.fileExists(atPath: handle.stagingURL.path) {
        guard try sha256(handle.stagingURL) == manifest.checksum else {
          throw ProductionPracticeError.recoveryRequired("Retained take checksum changed.")
        }
        if FileManager.default.fileExists(atPath: handle.finalURL.path) {
          guard try sha256(handle.finalURL) == manifest.checksum else {
            throw ProductionPracticeError.recoveryRequired(
              "Final take conflicts with staging audio.")
          }
          try FileManager.default.removeItem(at: handle.stagingURL)
        } else {
          try FileManager.default.moveItem(at: handle.stagingURL, to: handle.finalURL)
        }
      }
      guard FileManager.default.fileExists(atPath: handle.finalURL.path),
        try sha256(handle.finalURL) == manifest.checksum
      else { throw ProductionPracticeError.recoveryRequired("Retained take audio is missing.") }

      finalChecksum = manifest.checksum
      finalFrames = manifest.frameCount
    }

    try await database.commitPracticeTake(
      handle: handle, assetID: manifest.assetID,
      relativePath: "Takes/Final/\(handle.takeID.uuidString).caf",
      checksum: finalChecksum, sampleRate: manifest.sampleRate,
      frameCount: finalFrames, outcome: manifest.outcome)
    removeBestEffort(handle.stagingURL)
    removeBestEffort(handle.manifestURL)
    guard let take = try await database.practiceTakes(lessonID: handle.target.lessonID)
      .first(where: { $0.id == handle.takeID })
    else { throw ProductionPracticeError.persistence("Committed take could not be reloaded.") }
    return take
  }

  private func validate(_ handle: ProductionCaptureHandle) throws {
    let takeName = handle.takeID.uuidString
    guard handle.stagingURL.standardizedFileURL
      == paths.takeStaging.appendingPathComponent("\(takeName).caf").standardizedFileURL,
      handle.finalURL.standardizedFileURL
        == paths.finalTakes.appendingPathComponent("\(takeName).caf").standardizedFileURL,
      handle.manifestURL.standardizedFileURL
        == paths.takeStaging.appendingPathComponent("\(takeName).json").standardizedFileURL
    else {
      throw ProductionPracticeError.recoveryRequired("Take paths escaped managed storage.")
    }
  }

  private func removeDiscardedTakeFiles(
    _ records: [ProductionTakeDeletionRecord]
  ) throws -> Int64 {
    var removedBytes: Int64 = 0
    for record in records {
      let expected = paths.finalTakes.appendingPathComponent("\(record.takeID.uuidString).caf")
      guard record.relativePath == "Takes/Final/\(record.takeID.uuidString).caf" else {
        throw ProductionPracticeError.recoveryRequired("A recording path escaped managed storage.")
      }
      let staged = paths.deletingTakes.appendingPathComponent(expected.lastPathComponent)
      if FileManager.default.fileExists(atPath: expected.path) {
        guard !FileManager.default.fileExists(atPath: staged.path) else {
          throw ProductionPracticeError.recoveryRequired("A recording cleanup copy already exists.")
        }
        let values = try expected.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        removedBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        try FileManager.default.moveItem(at: expected, to: staged)
      } else if FileManager.default.fileExists(atPath: staged.path) {
        let values = try staged.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        removedBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
      }
      let receipt = RecordingSilenceTrimmer.receiptURL(for: expected)
      let stagedReceipt = paths.deletingTakes.appendingPathComponent(receipt.lastPathComponent)
      if FileManager.default.fileExists(atPath: receipt.path) {
        if FileManager.default.fileExists(atPath: stagedReceipt.path) {
          throw ProductionPracticeError.recoveryRequired("A recording receipt cleanup copy already exists.")
        }
        let values = try receipt.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        removedBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        try FileManager.default.moveItem(at: receipt, to: stagedReceipt)
      } else if FileManager.default.fileExists(atPath: stagedReceipt.path) {
        let values = try stagedReceipt.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        removedBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
      }
      for url in [staged, stagedReceipt] where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
    return removedBytes
  }

  private func removeBestEffort(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) }
    catch { logger.error("Remove take recovery file: \(error.localizedDescription, privacy: .public)") }
  }

  private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      do { try handle.close() }
      catch { logger.error("Close take file: \(error.localizedDescription, privacy: .public)") }
    }
    var hash = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

struct TakeCommitManifest: Codable, Sendable {
  let handle: ProductionCaptureHandle
  let assetID: UUID
  let checksum: String
  let sampleRate: Int
  let frameCount: Int
  let outcome: CaptureOutcome
  var trimPolicy: String? = nil
}
