import AVFAudio
import Foundation

/// Read-only, bounded signal preparation. No writes to audio or assessment history.
actor ReviewSignalAnalyzer {
  static let shared = ReviewSignalAnalyzer()
  private var waves: [ReviewAudioAsset: ReviewWaveform] = [:]
  private var contours: [ReviewAudioAsset: DeliveryTrack] = [:]
  private var order: [ReviewAudioAsset] = []

  func waveform(_ asset: ReviewAudioAsset) throws -> ReviewWaveform {
    try Task.checkCancellation()
    if let cached = waves[asset] { return cached }
    let file = try open(asset)
    let count = 640
    var peaks = Array(repeating: 0.0, count: count)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
      throw ProductionPracticeError.sourceUnavailable
    }
    file.framePosition = AVAudioFramePosition(asset.startFrame)
    let total = asset.endFrame - asset.startFrame
    var consumed = 0
    while consumed < total {
      try Task.checkCancellation()
      try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, total - consumed)))
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
        throw ProductionPracticeError.sourceUnavailable
      }
      for frame in 0..<Int(buffer.frameLength) {
        let bucket = min(count - 1, Int(Double(consumed + frame) / Double(total) * Double(count)))
        for channel in 0..<Int(buffer.format.channelCount) {
          let value = Double(channels[channel][frame])
          guard value.isFinite else { throw ProductionPracticeError.sourceUnavailable }
          peaks[bucket] = max(peaks[bucket], abs(value))
        }
      }
      consumed += Int(buffer.frameLength)
    }
    let result = ReviewWaveform(duration: asset.duration, peaks: peaks)
    try Task.checkCancellation()
    retain(asset)
    waves[asset] = result
    return result
  }

  func contour(_ asset: ReviewAudioAsset) throws -> DeliveryTrack {
    try Task.checkCancellation()
    if let cached = contours[asset] { return cached }
    guard asset.duration >= 0.04, asset.duration <= 30 else { throw BuddyError.invalidAudio }
    let file = try open(asset)
    let samples = try CoreMLWordAligner.samples(file: file, start: asset.offset,
      end: Double(asset.endFrame) / Double(asset.sampleRate))
    let result = try AcousticDeliveryAnalyzer.track(samples: samples)
    try Task.checkCancellation()
    retain(asset)
    contours[asset] = result
    return result
  }

  private func open(_ asset: ReviewAudioAsset) throws -> AVAudioFile {
    guard asset.sampleRate > 0, asset.startFrame >= 0, asset.endFrame > asset.startFrame else {
      throw ProductionPracticeError.invalidPlaybackRange
    }
    let file = try AVAudioFile(forReading: asset.url)
    guard file.processingFormat.sampleRate == Double(asset.sampleRate),
      asset.endFrame <= file.length else { throw ProductionPracticeError.invalidPlaybackRange }
    return file
  }

  private func retain(_ asset: ReviewAudioAsset) {
    order.removeAll { $0 == asset }; order.append(asset)
    while order.count > 24 {
      let oldest = order.removeFirst()
      waves.removeValue(forKey: oldest); contours.removeValue(forKey: oldest)
    }
  }
}
