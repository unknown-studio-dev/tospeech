import AVFAudio
import Foundation
import Observation

@MainActor @Observable
final class ProductionAudioPlayer {
  enum State: Equatable, Sendable { case idle, preparing, playing, paused, failed(String) }
  typealias SlowRenderer = @Sendable (URL, Int, Int, Double) async throws -> RubberBandRender
  typealias RecordingRenderer = @Sendable (URL, Bool) async throws -> PreparedRecordingAudio

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let secondPlayer = AVAudioPlayerNode()
  private let playbackGain = AVAudioUnitEQ(numberOfBands: 0)
  private let secondGain = AVAudioUnitEQ(numberOfBands: 0)
  private let takeMixer = AVAudioMixerNode()
  private var gainTask: Task<PreparedRecordingAudio, Error>?
  private var activeRecording: PreparedRecordingAudio?
  private struct GainKey: Hashable {
    let enhance: Bool
    let url: URL
    let modified: Date?
    let size: Int?
  }
  private var gainCache: [GainKey: PreparedRecordingAudio] = [:]
  private(set) var recordingGainDB: Float = 0
  private var secondFile: AVAudioFile?
  private var together: Together?
  private struct Together {
    let takeFrames: Range<Int>
    let takeRate: Double
    var sourceFinished = false
    var takeFinished = false
  }
  private(set) var assetURL: URL?
  private(set) var secondElapsed = 0.0
  var secondDuration: Double { together.map { Double($0.takeFrames.count) / $0.takeRate } ?? 0 }
  var isSimultaneous: Bool { together != nil }
  private let timePitch = AVAudioUnitTimePitch()
  private var file: AVAudioFile?
  private var rangeStart: AVAudioFramePosition = 0
  private var rangeEnd: AVAudioFramePosition = 0
  private var scheduledStart: AVAudioFramePosition = 0
  private var completion: (@MainActor @Sendable () -> Void)?
  private var ticker: Task<Void, Never>?
  private var scheduleToken = UUID()
  private let renderSlowAudio: SlowRenderer
  private let prepareRecordingAudio: RecordingRenderer
  var isRecordingEnhanced: Bool { activeRecording?.enhanced != nil }
  private var renderTask: Task<RubberBandRender, Error>?
  private var preparationTask: Task<Void, Never>?
  private var activeRender: RubberBandRender?
  private var cachedRender: (key: RenderKey, audio: RubberBandRender)?
  private var scheduledPlaybackStart: Int64 = 0
  private struct RenderKey: Equatable {
    let url: URL
    let modified: Date?
    let size: Int?
    let start: Int
    let end: Int
    let speed: Double
  }
  var onFailure: (@MainActor @Sendable (String) -> Void)?
  var isPreparing: Bool { renderTask != nil || gainTask != nil }
  var canSeek: Bool { !isSimultaneous && !isPreparing && (state == .playing || state == .paused) }

  private(set) var state: State = .idle
  private(set) var sourceFrame: AVAudioFramePosition = 0
  private(set) var sampleRate = 0.0
  private(set) var speed = 1.0

  init(renderSlowAudio: @escaping SlowRenderer = { url, start, end, speed in
    try await RubberBandRenderer.render(url: url, startFrame: start, endFrame: end, speed: speed)
  }, prepareRecordingAudio: @escaping RecordingRenderer = { url, enhance in
    try await DeepFilterRecordingRenderer.prepare(url: url, enhance: enhance)
  }) {
    self.renderSlowAudio = renderSlowAudio
    self.prepareRecordingAudio = prepareRecordingAudio
    engine.attach(player)
    engine.attach(secondPlayer)
    engine.attach(timePitch)
    engine.attach(playbackGain)
    engine.attach(secondGain)
    engine.attach(takeMixer)
  }

  var sourceSeconds: TimeInterval {
    sampleRate > 0 ? Double(sourceFrame) / sampleRate : 0
  }
  var rangeElapsed: Double { sampleRate > 0 ? max(0, Double(sourceFrame-rangeStart)/sampleRate) : 0 }
  var rangeDuration: Double { sampleRate > 0 ? Double(rangeEnd-rangeStart)/sampleRate : 0 }
  var rangeProgress: Double { rangeDuration > 0 ? min(1, rangeElapsed/rangeDuration) : 0 }

  func play(
    url: URL, startFrame: Int, endFrame: Int, speed: Double,
    startAtFrame: Int? = nil, playImmediately: Bool = true,
    levelRecording: Bool = false, enhanceRecording: Bool = false,
    onCompletion: @escaping @MainActor @Sendable () -> Void = {}
  ) throws {
    stop()
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw ProductionPracticeError.sourceUnavailable
    }
    let opened = try AVAudioFile(forReading: url)
    let initialFrame = startAtFrame ?? startFrame
    guard startFrame >= 0, endFrame > startFrame,
      AVAudioFramePosition(endFrame) <= opened.length,
      endFrame - startFrame <= Int(UInt32.max), speed.isFinite,
      (0.25...4).contains(speed), !levelRecording || speed == 1,
      initialFrame >= startFrame, initialFrame < endFrame
    else { throw ProductionPracticeError.invalidPlaybackRange }

    file = opened
    assetURL = url
    rangeStart = AVAudioFramePosition(startFrame)
    rangeEnd = AVAudioFramePosition(endFrame)
    sourceFrame = AVAudioFramePosition(initialFrame)
    sampleRate = opened.processingFormat.sampleRate
    self.speed = speed
    completion = onCompletion
    if speed < 1 {
      let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      let key = RenderKey(url: url, modified: values.contentModificationDate, size: values.fileSize,
        start: startFrame, end: endFrame, speed: speed)
      if let cachedRender, cachedRender.key == key {
        try useRender(cachedRender.audio, from: AVAudioFramePosition(initialFrame),
          playImmediately: playImmediately)
        return
      }
      state = playImmediately ? .preparing : .paused
      let token = scheduleToken
      let renderer = renderSlowAudio
      let worker = Task.detached(priority: .userInitiated) {
        try await renderer(url, startFrame, endFrame, speed)
      }
      renderTask = worker
      preparationTask = Task { [weak self] in
        do {
          let audio = try await worker.value
          guard let self, self.scheduleToken == token, !Task.isCancelled else { return }
          // `resume()` can change a paused preparation back to `.preparing`.
          // Honor that latest intent instead of the state when rendering began.
          let shouldPlay = self.state != .paused
          self.renderTask = nil
          self.preparationTask = nil
          self.cachedRender = (key, audio)
          try self.useRender(audio, from: AVAudioFramePosition(initialFrame),
            playImmediately: shouldPlay)
        } catch RubberBandRenderError.unavailable {
          // No bundled helper: AVAudioUnitTimePitch keeps slow playback working at lower quality.
          guard let self, self.scheduleToken == token, !Task.isCancelled else { return }
          let shouldPlay = self.state != .paused
          self.renderTask = nil
          self.preparationTask = nil
          do {
            try self.connectRegularPlayback(from: AVAudioFramePosition(initialFrame), playImmediately: shouldPlay)
          } catch {
            self.stop()
            self.state = .failed(error.localizedDescription)
            self.onFailure?(error.localizedDescription)
          }
        } catch {
          guard let self, self.scheduleToken == token, !Task.isCancelled else { return }
          self.stop()
          self.state = .failed(error.localizedDescription)
          self.onFailure?(error.localizedDescription)
        }
      }
      return
    }
    if levelRecording {
      try prepareRecordingGain(url: url, enhance: enhanceRecording) { [weak self] audio, shouldPlay in
        guard let self else { return }
        self.file = try AVAudioFile(forReading: audio.url)
        self.playbackGain.globalGain = audio.gain
        try self.connectRegularPlayback(playImmediately: shouldPlay)
      }
    } else {
      try connectRegularPlayback(
        from: AVAudioFramePosition(initialFrame), playImmediately: playImmediately)
    }
  }

  private func connectRegularPlayback(
    from frame: AVAudioFramePosition? = nil, playImmediately: Bool
  ) throws {
    guard let opened = file else { throw ProductionPracticeError.sourceUnavailable }
    timePitch.rate = Float(speed)
    timePitch.pitch = 0
    // More overlapping analysis windows reduce time-stretch artifacts at slow rates.
    timePitch.overlap = speed < 1 ? 32 : 8

    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(player, to: timePitch, format: opened.processingFormat)
    if recordingGainDB > 0 {
      engine.connect(timePitch, to: playbackGain, format: opened.processingFormat)
      engine.connect(playbackGain, to: engine.mainMixerNode, format: opened.processingFormat)
    } else { engine.connect(timePitch, to: engine.mainMixerNode, format: opened.processingFormat) }
    try schedule(from: frame ?? rangeStart, playImmediately: playImmediately)
  }

  /// Applies a new rate to the current source schedule without changing its
  /// source-audio playhead. An R3 rate may need preparation, then resumes from
  /// this same frame rather than restarting the sentence.
  func updateSpeed(_ value: Double) throws {
    guard value.isFinite, (0.25...4).contains(value), !isSimultaneous,
      let url = assetURL, file != nil,
      state == .playing || state == .paused || state == .preparing
    else { throw ProductionPracticeError.invalidPlaybackRange }
    guard value != speed else { return }
    if state == .playing { refreshPosition() }
    let frame = min(rangeEnd - 1, max(rangeStart, sourceFrame))
    let shouldPlay = state == .playing || state == .preparing
    let callback = completion
    try play(
      url: url, startFrame: Int(rangeStart), endFrame: Int(rangeEnd), speed: value,
      startAtFrame: Int(frame), playImmediately: shouldPlay,
      onCompletion: callback ?? {})
  }

  /// Both nodes use one engine and one host-time start. Each stream keeps its
  /// own frames/rate; neither audio is stretched or truncated to fit the other.
  func playTogether(sourceURL: URL, sourceFrames: Range<Int>, takeURL: URL, takeFrames: Range<Int>,
    levelRecording: Bool = false, enhanceRecording: Bool = false,
    onCompletion: @escaping @MainActor @Sendable () -> Void = {}) throws {
    stop()
    do {
      let source = try AVAudioFile(forReading: sourceURL)
      let take = try AVAudioFile(forReading: takeURL)
      for (range, audio) in [(sourceFrames, source), (takeFrames, take)] {
        guard range.lowerBound >= 0, !range.isEmpty, range.upperBound <= audio.length,
          range.count <= Int(UInt32.max) else { throw ProductionPracticeError.invalidPlaybackRange }
      }
      file = source
      secondFile = take
      assetURL = sourceURL
      sampleRate = source.processingFormat.sampleRate
      speed = 1
      rangeStart = Int64(sourceFrames.lowerBound)
      rangeEnd = Int64(sourceFrames.upperBound)
      scheduledStart = rangeStart
      sourceFrame = rangeStart
      together = Together(takeFrames: takeFrames, takeRate: take.processingFormat.sampleRate)
      completion = onCompletion
      if levelRecording {
        try prepareRecordingGain(url: takeURL, enhance: enhanceRecording) { [weak self] audio, shouldPlay in
          guard let self else { return }
          self.secondFile = try AVAudioFile(forReading: audio.url)
          self.secondGain.globalGain = audio.gain
          try self.connectTogetherPlayback(playImmediately: shouldPlay)
        }
      } else { try connectTogetherPlayback(playImmediately: true) }
    } catch { stop(); throw error }
  }

  private func connectTogetherPlayback(playImmediately: Bool) throws {
    guard let source = file, let take = secondFile, let together else { throw ProductionPracticeError.sourceUnavailable }
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.disconnectNodeOutput(secondPlayer)
    engine.connect(player, to: engine.mainMixerNode, format: source.processingFormat)
    engine.connect(secondPlayer, to: secondGain, format: take.processingFormat)
    engine.connect(secondGain, to: takeMixer, format: take.processingFormat)
    let stereo = AVAudioFormat(standardFormatWithSampleRate: take.processingFormat.sampleRate, channels: 2)!
    engine.connect(takeMixer, to: engine.mainMixerNode, format: stereo)
    player.pan = -1
    secondPlayer.pan = 0
    takeMixer.pan = 1
    player.volume = 0.8
    secondPlayer.volume = 0.8
    let token = scheduleToken
    player.scheduleSegment(source, startingFrame: rangeStart, frameCount: UInt32(rangeEnd - rangeStart), at: nil,
      completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.finishedTogether(token: token, source: true) }
    }
    secondPlayer.scheduleSegment(take, startingFrame: Int64(together.takeFrames.lowerBound), frameCount: UInt32(together.takeFrames.count), at: nil,
      completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.finishedTogether(token: token, source: false) }
    }
    try startTogetherNodes(playImmediately: playImmediately)
  }

  private func startTogetherNodes(playImmediately: Bool) throws {
    engine.prepare()
    if playImmediately {
      try engine.start()
      let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
      player.play(at: start); secondPlayer.play(at: start)
      state = .playing; startTicker()
    } else { state = .paused }
  }

  private func prepareRecordingGain(url: URL, enhance: Bool,
    ready: @escaping @MainActor (PreparedRecordingAudio, Bool) throws -> Void) throws {
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let key = GainKey(enhance: enhance, url: url, modified: values.contentModificationDate, size: values.fileSize)
    if let audio = gainCache[key] {
      activeRecording = audio; recordingGainDB = audio.gain
      try ready(audio, true)
      return
    }
    state = .preparing
    let token = scheduleToken
    let renderer = prepareRecordingAudio
    let worker = Task.detached(priority: .userInitiated) { try await renderer(url, enhance) }
    gainTask = worker
    preparationTask = Task { [weak self] in
      do {
        let audio = try await worker.value
        guard let self, self.scheduleToken == token, !Task.isCancelled else { return }
        let shouldPlay = self.state != .paused
        self.gainTask = nil; self.preparationTask = nil
        if self.gainCache.count >= 16 { self.gainCache.removeAll(keepingCapacity: true) }
        self.gainCache[key] = audio; self.activeRecording = audio; self.recordingGainDB = audio.gain
        try ready(audio, shouldPlay)
      } catch {
        guard let self, self.scheduleToken == token, !Task.isCancelled else { return }
        self.stop(); self.state = .failed(error.localizedDescription)
        self.onFailure?(error.localizedDescription)
      }
    }
  }

  private func finishedTogether(token: UUID, source: Bool) {
    guard token == scheduleToken, together != nil else { return }
    if source {
      together?.sourceFinished = true
      sourceFrame = rangeEnd
      player.stop()
    } else {
      together?.takeFinished = true
      secondElapsed = secondDuration
      secondPlayer.stop()
    }
    guard together?.sourceFinished == true, together?.takeFinished == true else { return }
    ticker?.cancel()
    ticker = nil
    engine.stop()
    state = .idle
    let callback = completion
    completion = nil
    callback?()
  }

  func pause() {
    if state == .preparing { state = .paused; return }
    guard state == .playing else { return }
    refreshPosition()
    player.pause()
    if isSimultaneous { secondPlayer.pause() }
    ticker?.cancel()
    ticker = nil
    state = .paused
  }

  func resume() throws {
    guard state == .paused, sourceFrame < rangeEnd || (isSimultaneous && together?.takeFinished == false) else { return }
    if isPreparing { state = .preparing; return }
    if !engine.isRunning { try engine.start() }
    if isSimultaneous {
      let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
      if together?.sourceFinished == false { player.play(at: start) }
      if together?.takeFinished == false { secondPlayer.play(at: start) }
    } else { player.play() }
    state = .playing
    startTicker()
  }

  func seek(to frame: Int) throws {
    guard file != nil, canSeek,
      frame >= Int(rangeStart), frame < Int(rangeEnd)
    else { throw ProductionPracticeError.invalidPlaybackRange }
    let shouldPlay = state == .playing
    player.stop()
    try schedule(from: AVAudioFramePosition(frame), playImmediately: shouldPlay)
  }

  func stop() {
    scheduleToken = UUID()
    renderTask?.cancel()
    renderTask = nil
    gainTask?.cancel()
    gainTask = nil
    preparationTask?.cancel()
    preparationTask = nil
    ticker?.cancel()
    ticker = nil
    player.stop()
    secondPlayer.stop()
    engine.stop()
    engine.disconnectNodeOutput(secondPlayer)
    engine.disconnectNodeOutput(playbackGain)
    engine.disconnectNodeOutput(secondGain)
    engine.disconnectNodeOutput(takeMixer)
    playbackGain.globalGain = 0
    secondGain.globalGain = 0
    recordingGainDB = 0
    player.pan = 0
    player.volume = 1
    secondFile = nil
    together = nil
    secondElapsed = 0
    assetURL = nil
    file = nil
    activeRender = nil
    activeRecording = nil
    completion = nil
    state = .idle
  }

  private func useRender(
    _ audio: RubberBandRender, from frame: AVAudioFramePosition? = nil,
    playImmediately: Bool
  ) throws {
    let opened = try AVAudioFile(forReading: audio.url)
    guard opened.length == audio.frameCount, opened.length > 0 else { throw RubberBandRenderError.incomplete }
    file = opened
    activeRender = audio
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    // R3 already stretched the span; feed it directly to the output at 1x.
    engine.connect(player, to: engine.mainMixerNode, format: opened.processingFormat)
    try schedule(from: frame ?? rangeStart, playImmediately: playImmediately)
  }

  private func schedule(from frame: AVAudioFramePosition, playImmediately: Bool) throws {
    guard let file else { throw ProductionPracticeError.sourceUnavailable }
    let playbackStart: Int64
    if let activeRender {
      playbackStart = min(activeRender.frameCount - 1,
        Int64((Double(frame - rangeStart) * Double(activeRender.frameCount) / Double(rangeEnd - rangeStart)).rounded()))
    } else { playbackStart = frame }
    let remaining = (activeRender?.frameCount ?? rangeEnd) - playbackStart
    guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else {
      throw ProductionPracticeError.invalidPlaybackRange
    }
    sourceFrame = frame
    scheduledStart = frame
    scheduledPlaybackStart = playbackStart
    let token = UUID()
    scheduleToken = token
    player.scheduleSegment(
      file, startingFrame: playbackStart, frameCount: AVAudioFrameCount(remaining), at: nil,
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
    if let together {
      if !together.takeFinished, let nodeTime = secondPlayer.lastRenderTime,
        let time = secondPlayer.playerTime(forNodeTime: nodeTime) {
        secondElapsed = min(secondDuration, Double(max(0, time.sampleTime)) / together.takeRate)
      }
      if together.sourceFinished { return }
    }
    guard let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else { return }
    if let activeRender {
      // R3's ratio varies locally around transients. This is the sentence's
      // approximate source clock for progress/seek, never learner alignment.
      let outputFrame = scheduledPlaybackStart + max(0, playerTime.sampleTime)
      sourceFrame = min(rangeEnd, rangeStart + Int64((Double(outputFrame)
        * Double(rangeEnd - rangeStart) / Double(activeRender.frameCount)).rounded()))
    } else {
      sourceFrame = min(rangeEnd, scheduledStart + max(0, playerTime.sampleTime))
    }
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
