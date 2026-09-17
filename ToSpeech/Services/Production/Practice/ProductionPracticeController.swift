import AVFAudio
import Foundation
import Observation

@MainActor @Observable
final class ProductionPracticeController {
  typealias SourcePlayback = @MainActor (
    ProductionPracticeTarget, Double, @escaping @MainActor @Sendable () -> Void
  ) throws -> Void
  typealias SourceSpeedUpdate = @MainActor (Double) throws -> Void
  private let service: ProductionPracticeService
  private let playSource: SourcePlayback
  private let updateSourceSpeed: SourceSpeedUpdate
  private let currentAuthorization: @MainActor () -> MicrophoneAuthorization
  private let requestPermission: @MainActor () async -> MicrophoneAuthorization
  /// Emitted after durable take commit; UI observation is not the queue trigger.
  var onTakeSaved: (@MainActor (ProductionStoredTake) -> Void)?
  /// Emitted only after a complete listen with repeat=1, never before capture.
  var onListenSequenceCompleted: (@MainActor (UUID, Bool) -> Void)?
  private var target: ProductionPracticeTarget?
  private var policy: ProductionCapturePolicy?
  private var sourceSpeed = 1.0
  private var captureAfterSource = false
  private var listened = false
  private var repeatEnabled = false
  private var repeatCount = 1
  private var autoRecord = false
  private var authorizationRequestID: UUID?
  private var permissionCheckID: UUID?
  private var captureStarting = false
  private var captureRequiresCompletedListen = true
  private var ticker: Task<Void, Never>?
  private var lastTick = ContinuousClock.now

  private(set) var phase: PracticePhase = .idle
  private(set) var remaining: TimeInterval = 0
  private(set) var elapsed: TimeInterval = 0
  private(set) var sourcePosition: TimeInterval = 0
  private(set) var inputLevelDB: Float = -120
  private(set) var permission = ProductionAudioRecorder.authorization
  private(set) var error: ProductionPracticeError?
  private(set) var lastTake: ProductionStoredTake?
  private(set) var round = 1
  /// Forgets the cached last take once its recording has been deleted; take lists
  /// merge it in to cover the just-saved window before the store refreshes.
  func discardLastTake(in ids: Set<UUID>) {
    if let lastTake, ids.contains(lastTake.id) { self.lastTake = nil }
  }
  private(set) var referenceDeliveryTrack: DeliveryTrack?
  private(set) var liveDeliveryTrack: DeliveryTrack?
  private var referencePrecomputeID: UUID?
  var currentTargetDuration: Double? { target?.duration }

  var hasListened: Bool { listened }
  var isRepeating: Bool { repeatEnabled }
  private(set) var canResumeSource = false
  var canSeekSource: Bool {
    guard phase == .listening || canResumeSource else { return false }
    return service.player.canSeek
  }
  var sourceSeekRange: ClosedRange<TimeInterval>? {
    guard let target else { return nil }
    return Double(target.startFrame) / Double(target.sampleRate)
      ... Double(target.playbackEndFrame) / Double(target.sampleRate)
  }

  init(service: ProductionPracticeService, playSource: SourcePlayback? = nil,
    updateSourceSpeed: SourceSpeedUpdate? = nil,
    currentAuthorization: (@MainActor () -> MicrophoneAuthorization)? = nil,
    requestPermission: (@MainActor () async -> MicrophoneAuthorization)? = nil
  ) {
    self.service = service
    self.currentAuthorization = currentAuthorization ?? { ProductionAudioRecorder.authorization }
    self.requestPermission = requestPermission ?? { await ProductionAudioRecorder.requestPermission() }
    self.playSource = playSource ?? { target, speed, completion in
      try service.play(target, speed: speed, onCompletion: completion)
    }
    self.updateSourceSpeed = updateSourceSpeed ?? { speed in
      try service.updatePlaybackSpeed(speed)
    }
  }

  func configure(
    target: ProductionPracticeTarget, sourceSpeed: Double,
    policy: ProductionCapturePolicy, repeatCount: Int = 1, autoRecord: Bool = false
  ) throws {
    guard !phase.isCapture, phase != .saving, phase != .saveFailed, !captureStarting else {
      throw ProductionPracticeError.recoveryRequired("Finish saving the current recording before changing its target.")
    }
    stopTicker()
    authorizationRequestID = nil
    permissionCheckID = nil
    service.stopPlayback()
    try target.validate()
    guard sourceSpeed.isFinite, sourceSpeed > 0 else {
      throw ProductionPracticeError.invalidPlaybackRange
    }
    self.target = target
    self.sourceSpeed = sourceSpeed
    self.policy = policy
    self.repeatCount = max(1, repeatCount)
    self.autoRecord = autoRecord
    sourcePosition = Double(target.startFrame) / Double(target.sampleRate)
    listened = false
    repeatEnabled = false
    captureRequiresCompletedListen = true
    round = 1
    canResumeSource = false
    lastTake = nil
    error = nil
    liveDeliveryTrack = nil
    phase = .idle
    precomputeReference(for: target)
  }

  /// Source-side contour for the sentence span, using the shared DSP. Pure so it
  /// can run off the main actor and be unit-tested from a fixture file.
  nonisolated static func referenceTrack(target: ProductionPracticeTarget) throws -> DeliveryTrack {
    let file = try AVAudioFile(forReading: target.audioURL)
    let start = Double(target.startFrame) / Double(target.sampleRate)
    let end = Double(target.endFrame) / Double(target.sampleRate)
    return try AcousticDeliveryAnalyzer.track(samples: CoreMLWordAligner.samples(file: file, start: start, end: end))
  }

  private func precomputeReference(for target: ProductionPracticeTarget) {
    let requestID = UUID()
    referencePrecomputeID = requestID
    referenceDeliveryTrack = nil
    Task { [weak self] in
      let track = await Task.detached(priority: .utility) {
        try? Self.referenceTrack(target: target)
      }.value
      guard let self, self.referencePrecomputeID == requestID else { return }
      self.referenceDeliveryTrack = track
    }
  }

  func setSourceSpeed(_ value: Double) {
    guard value.isFinite, (0.25...4).contains(value), !phase.isCapture, phase != .saving else {
      return
    }
    _ = applySourceSpeed(value)
  }

  func updateOptions(
    sourceSpeed: Double, policy: ProductionCapturePolicy,
    repeatCount: Int, autoRecord: Bool
  ) {
    guard sourceSpeed.isFinite, (0.25...4).contains(sourceSpeed), !phase.isCapture,
      phase != .saving, phase != .saveFailed
    else { return }
    guard applySourceSpeed(sourceSpeed) else { return }
    self.policy = policy
    self.repeatCount = max(1, repeatCount)
    self.autoRecord = autoRecord
    round = min(round, self.repeatCount)
  }

  private func applySourceSpeed(_ value: Double) -> Bool {
    guard value != sourceSpeed else { return true }
    if phase == .listening || canResumeSource {
      do {
        try updateSourceSpeed(value)
      } catch {
        fail(error)
        canResumeSource = false
        return false
      }
    }
    sourceSpeed = value
    return true
  }

  func listen(repeating: Bool = false, thenCapture: Bool = false) {
    guard let target, !phase.isCapture, phase != .saving, phase != .saveFailed,
      phase != .countdown, !captureStarting, authorizationRequestID == nil else { return }
    if canResumeSource && repeating == repeatEnabled {
      resumeFromSource()
      return
    }
    stopTicker()
    round = 1
    repeatEnabled = repeating
    captureAfterSource = thenCapture
    listened = false
    canResumeSource = false
    error = nil
    phase = .listening
    do {
      try playSource(target, sourceSpeed) { [weak self] in
        self?.sourceFinished(revisionID: target.segmentRevisionID)
      }
      startTicker()
    } catch {
      fail(error)
    }
  }

  func requestRecord() {
    guard phase != .saving, phase != .saveFailed, !phase.isCapture,
      phase != .countdown, !captureStarting, authorizationRequestID == nil else { return }
    stopTicker()
    service.stopPlayback()
    captureAfterSource = false
    repeatEnabled = false
    canResumeSource = false
    error = nil
    phase = .paused
    Task { [weak self] in
      await self?.authorizeAndCountDown(requiresCompletedListen: false)
    }
  }

  func retryRecordPermission() {
    error = nil
    permission = currentAuthorization()
    requestRecord()
  }

  func checkMicrophonePermission() {
    error = nil
    permission = currentAuthorization()
    guard permission == .notDetermined, permissionCheckID == nil else { return }
    let requestID = UUID()
    permissionCheckID = requestID
    Task { [weak self] in
      guard let self else { return }
      let result = await self.requestPermission()
      guard self.permissionCheckID == requestID else { return }
      self.permissionCheckID = nil
      self.permission = result
    }
  }

  func cancelCountdown() {
    guard phase == .countdown else { return }
    stopTicker()
    captureAfterSource = false
    repeatEnabled = false
    captureRequiresCompletedListen = true
    remaining = 0
    phase = .paused
  }

  func finishRecording(reachedDurationLimit: Bool = false) {
    guard phase.isCapture, let policy else { return }
    phase = .saving
    stopTicker()
    Task { [weak self] in
      guard let self else { return }
      do {
        self.lastTake = try await self.service.finishCapture(policy: policy, reachedDurationLimit: reachedDurationLimit)
        self.elapsed = self.lastTake.map {
          Double($0.frameCount ?? 0) / Double($0.sampleRate ?? 1)
        } ?? 0
        self.continueAfterSavedTake(self.lastTake)
      } catch {
        self.phase = .saveFailed
        self.fail(error, preservingPhase: true)
      }
    }
  }

  func retrySave() {
    guard phase == .saveFailed else { return }
    phase = .saving
    Task { [weak self] in
      guard let self else { return }
      do {
        self.lastTake = try await self.service.retrySave()
        self.error = nil
        self.continueAfterSavedTake(self.lastTake)
      } catch {
        self.phase = .saveFailed
        self.fail(error, preservingPhase: true)
      }
    }
  }

  func discardPending() {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.service.discardPending()
        self.error = nil
        self.captureAfterSource = false
        self.repeatEnabled = false
        self.listened = false
        self.canResumeSource = false
        self.phase = .paused
        self.liveDeliveryTrack = nil
      } catch {
        self.fail(error)
      }
    }
  }

  func pauseAndKeep() {
    authorizationRequestID = nil
    switch phase {
    case .listening:
      service.pausePlayback()
      stopTicker()
      canResumeSource = true
      phase = .paused
    case .countdown:
      stopTicker()
      captureAfterSource = true
      phase = .paused
    case .awaitingSpeech, .recording, .trailingSilence:
      guard let policy else { return }
      phase = .saving
      stopTicker()
      Task { [weak self] in
        guard let self else { return }
        do {
          self.lastTake = try await self.service.finishCapture(
            policy: policy, interrupted: true)
          self.captureAfterSource = false
          self.repeatEnabled = false
          self.listened = false
          self.canResumeSource = false
          self.phase = .paused
        } catch {
          self.phase = .saveFailed
          self.fail(error, preservingPhase: true)
        }
      }
    default: break
    }
  }

  func playbackFailed(_ message: String) {
    guard phase == .listening || canResumeSource else { return }
    listened = false
    canResumeSource = false
    fail(ProductionPracticeError.playback(message))
  }

  func resumeFromSource() {
    guard canResumeSource, service.player.state == .paused else {
      canResumeSource = false
      return
    }
    do {
      try service.resumePlayback()
      canResumeSource = false
      phase = .listening
      startTicker()
    } catch {
      fail(error)
    }
  }

  func seekSource(to seconds: TimeInterval) {
    guard let target, canSeekSource else { return }
    let requested = Int((seconds * Double(target.sampleRate)).rounded())
    let frame = min(target.playbackEndFrame - 1, max(target.startFrame, requested))
    do {
      try service.player.seek(to: frame)
      sourcePosition = Double(frame) / Double(target.sampleRate)
    }
    catch { fail(error) }
  }

  /// A word/timing/take preview reuses the audio player, so a paused source
  /// schedule can no longer be resumed after that preview replaces it.
  func prepareForAuxiliaryPlayback() {
    authorizationRequestID = nil
    if phase == .listening { service.pausePlayback() }
    stopTicker()
    canResumeSource = false
    captureAfterSource = false
    repeatEnabled = false
    if phase == .listening { phase = .paused }
  }

  private func authorizeAndCountDown(requiresCompletedListen: Bool = true) async {
    guard authorizationRequestID == nil, (!requiresCompletedListen || listened), !captureStarting,
      !phase.isCapture, phase != .saving, phase != .saveFailed, phase != .countdown else { return }
    let requestID = UUID()
    authorizationRequestID = requestID
    let revisionID = target?.segmentRevisionID
    defer { if authorizationRequestID == requestID { authorizationRequestID = nil } }
    permission = currentAuthorization()
    if permission == .notDetermined {
      permission = await requestPermission()
    }
    guard authorizationRequestID == requestID, target?.segmentRevisionID == revisionID else { return }
    guard permission == .granted else {
      fail(ProductionPracticeError.microphoneDenied)
      return
    }
    service.stopPlayback()
    captureRequiresCompletedListen = requiresCompletedListen
    beginCountdown()
  }

  private func sourceFinished(revisionID: UUID) {
    guard phase == .listening, target?.segmentRevisionID == revisionID else { return }
    stopTicker()
    canResumeSource = false
    if let target { sourcePosition = Double(target.playbackEndFrame) / Double(target.sampleRate) }
    listened = true
    if captureAfterSource || autoRecord {
      captureAfterSource = false
      Task { [weak self] in await self?.authorizeAndCountDown() }
    } else if repeatEnabled && round < repeatCount {
      round += 1
      startSourceRound()
    } else {
      phase = .paused
      if (repeatCount == 1 || repeatEnabled), target?.scope == .sentence {
        onListenSequenceCompleted?(revisionID, repeatEnabled)
      }
    }
  }

  private func startSourceRound() {
    guard let target else { return }
    stopTicker()
    listened = false
    canResumeSource = false
    error = nil
    sourcePosition = Double(target.startFrame) / Double(target.sampleRate)
    phase = .listening
    do {
      try playSource(target, sourceSpeed) { [weak self] in
        self?.sourceFinished(revisionID: target.segmentRevisionID)
      }
      startTicker()
    } catch {
      fail(error)
    }
  }

  private func continueAfterSavedTake(_ take: ProductionStoredTake?) {
    if let take { onTakeSaved?(take) }
    if take?.outcome != .interrupted, repeatEnabled, round < repeatCount {
      round += 1
      startSourceRound()
    } else {
      repeatEnabled = false
      listened = false
      canResumeSource = false
      phase = .feedback
      liveDeliveryTrack = nil
    }
  }

  private func beginCountdown() {
    guard let policy else { return }
    phase = .countdown
    remaining = policy.countdown
    elapsed = 0
    if remaining == 0 {
      beginCapture()
    } else {
      startTicker()
    }
  }

  private func beginCapture() {
    guard let target, let policy, !captureStarting else { return }
    stopTicker()
    captureStarting = true
    phase = .saving
    Task { [weak self] in
      guard let self else { return }
      defer { self.captureStarting = false }
      do {
        _ = try await self.service.startCapture(
          target: target, sourceSpeed: self.sourceSpeed, policy: policy,
          requiresCompletedListen: self.captureRequiresCompletedListen)
        self.phase = .awaitingSpeech
        self.elapsed = 0
        self.remaining = policy.trailingSilence
        self.liveDeliveryTrack = nil
        self.startTicker()
      } catch {
        self.fail(error)
      }
    }
  }

  private func startTicker() {
    stopTicker()
    lastTick = .now
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        self?.tick()
      }
    }
  }

  private func stopTicker() {
    ticker?.cancel()
    ticker = nil
  }

  private func tick() {
    let now = ContinuousClock.now
    let delta = lastTick.duration(to: now).timeInterval
    lastTick = now
    guard delta.isFinite, delta > 0 else { return }
    switch phase {
    case .listening:
      sourcePosition = service.player.sourceSeconds
    case .countdown:
      remaining = max(0, remaining - delta)
      if remaining == 0 { beginCapture() }
    case .awaitingSpeech, .recording, .trailingSilence:
      guard let policy else { return }
      // A disconnected input may stop delivering frames; the wall-clock cap still applies.
      elapsed = max(elapsed + delta, service.recorder.elapsed)
      if case .failed = service.recorder.state {
        finishRecording()
        return
      }
      inputLevelDB = service.recorder.levelDB
      liveDeliveryTrack = service.recorder.liveTrack
      switch CaptureTick.decide(
        phase: phase, elapsed: elapsed, remaining: remaining, delta: delta,
        levelDB: inputLevelDB, policy: policy)
      {
      case .finish(let reachedLimit):
        finishRecording(reachedDurationLimit: reachedLimit)
      case .advance(let nextPhase, let nextRemaining):
        phase = nextPhase
        remaining = nextRemaining
      }
    default: break
    }
  }

  private func fail(_ failure: any Error, preservingPhase: Bool = false) {
    if let failure = failure as? ProductionPracticeError {
      error = failure
    } else {
      error = .persistence(failure.localizedDescription)
    }
    if !preservingPhase { phase = .paused }
    stopTicker()
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
  }
}
