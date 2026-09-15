import AVFAudio
import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class ProductionAudioRecorder {
  enum State: Equatable, Sendable { case idle, recording, failed(String) }

  private let engine = AVAudioEngine()
  private var writer: CaptureWriter?
  private var meterTask: Task<Void, Never>?

  private(set) var state: State = .idle
  private(set) var elapsed: TimeInterval = 0
  private(set) var levelDB: Float = -120
  private(set) var speechDetected = false
  private(set) var liveTrack: DeliveryTrack?
  private var liveTask: Task<Void, Never>?

  static var authorization: MicrophoneAuthorization {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined: .notDetermined
    case .authorized: .granted
    case .denied: .denied
    case .restricted: .restricted
    @unknown default: .restricted
    }
  }

  static func requestPermission() async -> MicrophoneAuthorization {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    return granted ? .granted : .denied
  }

  func start(to url: URL, policy: ProductionCapturePolicy) throws {
    guard Self.authorization == .granted else { throw ProductionPracticeError.microphoneDenied }
    stopWithoutArtifact()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw ProductionPracticeError.microphoneUnavailable
    }
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings,
      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    let writer = CaptureWriter(file: file, url: url, thresholdDB: policy.speechThresholdDB,
      nativeSampleRate: format.sampleRate, channelCount: Int(format.channelCount))
    self.writer = writer
    input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: writer.makeAudioTap())
    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      self.writer = nil
      throw ProductionPracticeError.microphoneUnavailable
    }
    elapsed = 0
    levelDB = -120
    speechDetected = false
    state = .recording
    startMetering(sampleRate: format.sampleRate)
    liveTrack = nil
    startLiveAnalysis()
  }

  func finish() throws -> ProductionCaptureArtifact {
    let canFinish: Bool
    switch state {
    case .recording, .failed: canFinish = true
    case .idle: canFinish = false
    }
    guard canFinish, let writer else {
      throw ProductionPracticeError.captureNotRunning
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    meterTask?.cancel()
    meterTask = nil
    liveTask?.cancel()
    liveTask = nil
    let snapshot = writer.finish()
    self.writer = nil
    state = .idle
    if let error = snapshot.error {
      throw ProductionPracticeError.captureWrite(error)
    }
    let file = try AVAudioFile(forReading: snapshot.url)
    guard file.length > 0 else {
      throw ProductionPracticeError.captureWrite("The captured audio file is empty.")
    }
    return ProductionCaptureArtifact(
      url: snapshot.url, sampleRate: Int(file.processingFormat.sampleRate),
      frameCount: Int(file.length), peakDB: snapshot.peakDB,
      voicedFrames: snapshot.voicedFrames)
  }

  func stopWithoutArtifact() {
    if writer != nil { engine.inputNode.removeTap(onBus: 0) }
    engine.stop()
    meterTask?.cancel()
    meterTask = nil
    liveTask?.cancel()
    liveTask = nil
    writer = nil
    state = .idle
    elapsed = 0
    levelDB = -120
    speechDetected = false
    liveTrack = nil
  }

  private func startMetering(sampleRate: Double) {
    meterTask?.cancel()
    meterTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard let self, let writer = self.writer else { return }
        let snapshot = writer.snapshot()
        self.levelDB = snapshot.levelDB
        self.speechDetected = snapshot.voicedFrames > 0
        self.elapsed = Double(snapshot.frameCount) / sampleRate
        if let error = snapshot.error {
          self.state = .failed(error)
          return
        }
      }
    }
  }

  private func startLiveAnalysis() {
    liveTask?.cancel()
    liveTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard let self, let writer = self.writer else { return }
        let snap = writer.liveMonoSnapshot()
        let track = await Task.detached(priority: .utility) {
          LiveDeliveryContour.track(monoSamples: snap.samples, inputSampleRate: snap.sampleRate)
        }.value
        if Task.isCancelled { return }
        self.liveTrack = track
      }
    }
  }
}

final class CaptureWriter: @unchecked Sendable {
  struct Snapshot: Sendable {
    let url: URL
    let frameCount: Int
    let voicedFrames: Int
    let levelDB: Float
    let peakDB: Float
    let error: String?
  }

  private let lock = NSLock()
  private var file: AVAudioFile?
  private let url: URL
  private let thresholdDB: Float
  private var frameCount = 0
  private var voicedFrames = 0
  private var levelDB: Float = -120
  private var peakDB: Float = -120
  private var error: String?
  private let nativeSampleRate: Double
  private let channelCount: Int
  private var monoSamples: [Float] = []
  private let maxLiveSamples: Int   // ~35s cap

  init(file: AVAudioFile, url: URL, thresholdDB: Float, nativeSampleRate: Double, channelCount: Int) {
    self.file = file
    self.url = url
    self.thresholdDB = thresholdDB
    self.nativeSampleRate = nativeSampleRate
    self.channelCount = max(1, channelCount)
    self.maxLiveSamples = Int(nativeSampleRate * 35)
  }

  /// AVAudioEngine invokes its tap on an audio queue. Construct the closure
  /// outside MainActor so Swift does not assert UI isolation on the first buffer.
  /// Consume synchronously: the engine owns the buffer's lifetime; UI observes
  /// only locked value snapshots through the recorder's MainActor meter task.
  nonisolated func makeAudioTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { [self] buffer, _ in consume(buffer) }
  }

  func consume(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard error == nil, let file else { return }
    do { try file.write(from: buffer) }
    catch {
      self.error = error.localizedDescription
      return
    }
    let frames = Int(buffer.frameLength)
    frameCount += frames
    guard frames > 0, let channels = buffer.floatChannelData else { return }
    var sum: Float = 0
    let channelCount = Int(buffer.format.channelCount)
    for channel in 0..<channelCount {
      let values = channels[channel]
      for index in 0..<frames { sum += values[index] * values[index] }
    }
    let rms = sqrt(sum / Float(frames * channelCount))
    levelDB = 20 * log10(max(rms, 0.000_001))
    peakDB = max(peakDB, levelDB)
    if levelDB >= thresholdDB { voicedFrames += frames }
    // downmix to mono for the live contour; audio thread stays cheap (no DSP here)
    var mono = [Float](); mono.reserveCapacity(frames)
    for index in 0..<frames {
      var acc: Float = 0
      for channel in 0..<channelCount { acc += channels[channel][index] }
      mono.append(acc / Float(channelCount))
    }
    monoSamples.append(contentsOf: mono)
    if monoSamples.count > maxLiveSamples {
      monoSamples.removeFirst(monoSamples.count - maxLiveSamples)
    }
  }

  /// Close the CAF writer before probing duration/checksum or publishing the file.
  func finish() -> Snapshot {
    lock.lock()
    file = nil
    lock.unlock()
    return snapshot()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      url: url, frameCount: frameCount, voicedFrames: voicedFrames,
      levelDB: levelDB, peakDB: peakDB, error: error)
  }

  func liveMonoSnapshot() -> (samples: [Float], sampleRate: Double) {
    lock.lock(); defer { lock.unlock() }
    return (monoSamples, nativeSampleRate)
  }
}
