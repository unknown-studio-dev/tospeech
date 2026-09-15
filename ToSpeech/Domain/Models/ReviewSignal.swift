import Foundation

/// Immutable file range on this recording's own clock, never a mapped source range.
struct ReviewAudioAsset: Hashable, Sendable, Identifiable {
  let id: String
  let url: URL
  let sampleRate: Int
  let startFrame: Int
  let endFrame: Int
  var duration: Double { sampleRate > 0 ? Double(endFrame - startFrame) / Double(sampleRate) : 0 }
  var offset: Double { sampleRate > 0 ? Double(startFrame) / Double(sampleRate) : 0 }
}

struct ReviewWaveform: Equatable, Sendable {
  let duration: Double
  /// Absolute linear PCM peaks. Display gain is independent of the time axis.
  let peaks: [Double]
}

enum ReviewSignalScale {
  static func duration(_ values: [Double]) -> Double {
    max(0.001, values.filter { $0.isFinite && $0 > 0 }.max() ?? 0)
  }

  static func fraction(time: Double, duration: Double) -> Double? {
    guard time.isFinite, duration.isFinite, duration > 0, time >= 0, time <= duration else { return nil }
    return time / duration
  }

  /// Reject clicks after a shorter track ends instead of borrowing the other clock.
  static func playbackStart(fraction: Double, scale: Double, asset: ReviewAudioAsset) -> Double? {
    guard fraction.isFinite, scale.isFinite, scale > 0, (0...1).contains(fraction),
      asset.duration > 0, asset.sampleRate > 0 else { return nil }
    let local = fraction * scale
    guard local >= 0, local < asset.duration - 0.04 else { return nil }
    return asset.offset + local
  }
}
