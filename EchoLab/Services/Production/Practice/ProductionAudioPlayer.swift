import AVFAudio
import Foundation
import Observation

@MainActor @Observable
final class ProductionAudioPlayer {
  enum State: Equatable, Sendable { case idle, playing, paused, failed(String) }

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var file: AVAudioFile?
  private var rangeStart: AVAudioFramePosition = 0
  private var rangeEnd: AVAudioFramePosition = 0
  private var scheduledStart: AVAudioFramePosition = 0
  private var completion: (@MainActor @Sendable () -> Void)?
  private var ticker: Task<Void, Never>?
  private var scheduleToken = UUID()

  private(set) var state: State = .idle
  private(set) var sourceFrame: AVAudioFramePosition = 0
  private(set) var sampleRate = 0.0
  private(set) var speed = 1.0

  init() {
    engine.attach(player)
    engine.attach(timePitch)
  }

  var sourceSeconds: TimeInterval {
    sampleRate > 0 ? Double(sourceFrame) / sampleRate : 0
  }

  func play(
    url: URL, startFrame: Int, endFrame: Int, speed: Double,
    onCompletion: @escaping @MainActor @Sendable () -> Void = {}
  ) throws {
    stop()
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw ProductionPracticeError.sourceUnavailable
    }
    let opened = try AVAudioFile(forReading: url)
    guard startFrame >= 0, endFrame > startFrame,
      AVAudioFramePosition(endFrame) <= opened.length,
      endFrame - startFrame <= Int(UInt32.max), speed.isFinite,
      (0.25...4).contains(speed)
    else { throw ProductionPracticeError.invalidPlaybackRange }

    file = opened
    rangeStart = AVAudioFramePosition(startFrame)
    rangeEnd = AVAudioFramePosition(endFrame)
    sourceFrame = rangeStart
    sampleRate = opened.processingFormat.sampleRate
    self.speed = speed
    completion = onCompletion
    timePitch.rate = Float(speed)

    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(player, to: timePitch, format: opened.processingFormat)
    engine.connect(timePitch, to: engine.mainMixerNode, format: opened.processingFormat)
    try schedule(from: rangeStart, playImmediately: true)
  }

  func pause() {
    guard state == .playing else { return }
    refreshPosition()
    player.pause()
    ticker?.cancel()
    ticker = nil
    state = .paused
  }

  func resume() throws {
    guard state == .paused, sourceFrame < rangeEnd else { return }
    if !engine.isRunning { try engine.start() }
    player.play()
    state = .playing
    startTicker()
  }

  func seek(to frame: Int) throws {
    guard file != nil, [.playing, .paused].contains(state),
      frame >= Int(rangeStart), frame < Int(rangeEnd)
    else { throw ProductionPracticeError.invalidPlaybackRange }
    let shouldPlay = state == .playing
    player.stop()
    try schedule(from: AVAudioFramePosition(frame), playImmediately: shouldPlay)
  }

  func stop() {
    scheduleToken = UUID()
    ticker?.cancel()
    ticker = nil
    player.stop()
    engine.stop()
    file = nil
    completion = nil
    state = .idle
  }

  private func schedule(from frame: AVAudioFramePosition, playImmediately: Bool) throws {
    guard let file else { throw ProductionPracticeError.sourceUnavailable }
    let remaining = rangeEnd - frame
    guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else {
      throw ProductionPracticeError.invalidPlaybackRange
    }
    sourceFrame = frame
    scheduledStart = frame
    let token = UUID()
    scheduleToken = token
    player.scheduleSegment(
      file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      Task { @MainActor in self?.finished(token: token) }
    }
    engine.prepare()
    if !engine.isRunning { try engine.start() }
    if playImmediately {
      player.play()
      state = .playing
      startTicker()
    } else {
      state = .paused
    }
  }

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        guard let self else { return }
        self.refreshPosition()
      }
    }
  }

  private func refreshPosition() {
    guard let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else { return }
    sourceFrame = min(rangeEnd, scheduledStart + max(0, playerTime.sampleTime))
  }

  private func finished(token: UUID) {
    guard token == scheduleToken else { return }
    sourceFrame = rangeEnd
    ticker?.cancel()
    ticker = nil
    player.stop()
    engine.stop()
    state = .idle
    let callback = completion
    completion = nil
    callback?()
  }
}
