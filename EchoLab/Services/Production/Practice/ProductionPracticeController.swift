import Foundation
import Observation

@MainActor @Observable
final class ProductionPracticeController {
  typealias SourcePlayback = @MainActor (
    ProductionPracticeTarget, Double, @escaping @MainActor @Sendable () -> Void
  ) throws -> Void
  private let service: ProductionPracticeService
  private let playSource: SourcePlayback
  /// Emitted only after a complete listen with repeat=1, never before capture.
  var onSingleListenCompleted: (@MainActor (UUID, Bool) -> Void)?
  private var target: ProductionPracticeTarget?
  private var policy: ProductionCapturePolicy?
  private var sourceSpeed = 1.0
  private var captureAfterSource = false
  private var listened = false
  private var repeatEnabled = false
  private var repeatCount = 1
  private var autoRecord = false
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

  var hasListened: Bool { listened }
  var isRepeating: Bool { repeatEnabled }
  private(set) var canResumeSource = false
  var canSeekSource: Bool {
    guard phase == .listening || canResumeSource else { return false }
    return service.player.state == .playing || service.player.state == .paused
  }
  var sourceSeekRange: ClosedRange<TimeInterval>? {
    guard let target else { return nil }
    return Double(target.startFrame) / Double(target.sampleRate)
      ... Double(target.playbackEndFrame) / Double(target.sampleRate)
  }

  init(service: ProductionPracticeService, playSource: SourcePlayback? = nil) {
    self.service = service
    self.playSource = playSource ?? { target, speed, completion in
      try service.play(target, speed: speed, onCompletion: completion)
    }
  }

  func configure(
    target: ProductionPracticeTarget, sourceSpeed: Double,
    policy: ProductionCapturePolicy, repeatCount: Int = 1, autoRecord: Bool = false
  ) throws {
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
    round = 1
    canResumeSource = false
    lastTake = nil
    error = nil
    phase = .idle
  }

  func setSourceSpeed(_ value: Double) {
    guard value.isFinite, (0.25...4).contains(value), !phase.isCapture, phase != .saving else {
      return
    }
    sourceSpeed = value
  }

  func updateOptions(
    sourceSpeed: Double, policy: ProductionCapturePolicy,
    repeatCount: Int, autoRecord: Bool
  ) {
    guard sourceSpeed.isFinite, (0.25...4).contains(sourceSpeed), !phase.isCapture,
      phase != .saving, phase != .saveFailed
    else { return }
    self.sourceSpeed = sourceSpeed
    self.policy = policy
    self.repeatCount = max(1, repeatCount)
    self.autoRecord = autoRecord
    round = min(round, self.repeatCount)
  }

  func listen(repeating: Bool = false, thenCapture: Bool = false) {
    guard let target else { return }
    if canResumeSource && repeating == repeatEnabled {
      resumeFromSource()
      return
    }
    stopTicker()
    if repeating && phase != .paused { round = 1 }
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
    guard phase != .saving && phase != .saveFailed && !phase.isCapture else { return }
    guard listened else {
      fail(ProductionPracticeError.sourceMustBeListenedFirst)
      return
    }
    Task { [weak self] in await self?.authorizeAndCountDown() }
  }

  func retryRecordPermission() {
    error = nil
    permission = ProductionAudioRecorder.authorization
    requestRecord()
  }

  func cancelCountdown() {
    guard phase == .countdown else { return }
    stopTicker()
    captureAfterSource = false
    repeatEnabled = false
    remaining = 0
    phase = .paused
  }

  func finishRecording() {
    guard phase.isCapture, let policy else { return }
    phase = .saving
    stopTicker()
    Task { [weak self] in
      guard let self else { return }
      do {
        self.lastTake = try await self.service.finishCapture(policy: policy)
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
      } catch {
        self.fail(error)
      }
    }
  }

  func pauseAndKeep() {
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
    if phase == .listening { service.pausePlayback() }
    stopTicker()
    canResumeSource = false
    captureAfterSource = false
    repeatEnabled = false
    if phase == .listening { phase = .paused }
  }

  private func authorizeAndCountDown() async {
    permission = ProductionAudioRecorder.authorization
    if permission == .notDetermined {
      permission = await ProductionAudioRecorder.requestPermission()
    }
    guard permission == .granted else {
      fail(ProductionPracticeError.microphoneDenied)
      return
    }
    beginCountdown()
  }

  private func sourceFinished(revisionID: UUID) {
    guard phase == .listening, target?.segmentRevisionID == revisionID else { return }
    stopTicker()
    canResumeSource = false
    if let target { sourcePosition = Double(target.playbackEndFrame) / Double(target.sampleRate) }
    listened = true
    if captureAfterSource || (repeatEnabled && autoRecord) {
      captureAfterSource = false
      Task { [weak self] in await self?.authorizeAndCountDown() }
    } else if repeatEnabled && round < repeatCount {
      round += 1
      startSourceRound()
    } else {
      phase = .paused
      if repeatCount == 1, target?.scope == .sentence {
        onSingleListenCompleted?(revisionID, repeatEnabled)
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
    if take?.outcome != .interrupted, repeatEnabled, round < repeatCount {
      round += 1
      startSourceRound()
    } else {
      repeatEnabled = false
      listened = false
      canResumeSource = false
      phase = .feedback
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
    guard let target, let policy else { return }
    stopTicker()
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.service.startCapture(
          target: target, sourceSpeed: self.sourceSpeed, policy: policy)
        self.phase = .awaitingSpeech
        self.elapsed = 0
        self.remaining = policy.trailingSilence
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
      elapsed = service.recorder.elapsed
      inputLevelDB = service.recorder.levelDB
      if elapsed >= policy.maximumDuration {
        finishRecording()
        return
      }
      let speaking = inputLevelDB >= policy.speechThresholdDB
      if speaking {
        phase = .recording
        remaining = policy.trailingSilence
      } else if phase == .recording {
        phase = .trailingSilence
        remaining = policy.trailingSilence
      } else if phase == .trailingSilence {
        remaining = max(0, remaining - delta)
        if remaining == 0 { finishRecording() }
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
