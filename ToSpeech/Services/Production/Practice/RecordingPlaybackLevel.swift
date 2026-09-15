import AVFAudio
import Foundation

/// Constant playback gain over the whole take, preserving within-take dynamics.
/// No file writes, denoising, compression, or changes to assessment input.
enum RecordingPlaybackLevel {
  static func gain(url: URL) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard (8_000...192_000).contains(format.sampleRate), (1...8).contains(format.channelCount),
      file.length > 0, Double(file.length) / format.sampleRate <= 600,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(format.sampleRate * 0.02))
    else { throw ProductionPracticeError.invalidPlaybackRange }
    var blocks: [Double] = [], peak = 0.0
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: buffer)
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
        throw ProductionPracticeError.sourceUnavailable
      }
      var energy = 0.0
      for channel in 0..<Int(format.channelCount) {
        var channelEnergy = 0.0
        for frame in 0..<Int(buffer.frameLength) {
          let value = Double(channels[channel][frame])
          guard value.isFinite else { throw ProductionPracticeError.sourceUnavailable }
          peak = max(peak, abs(value)); channelEnergy += value * value
        }
        // A silent stereo channel must not make us over-amplify the active one.
        energy = max(energy, channelEnergy / Double(buffer.frameLength))
      }
      blocks.append(energy)
    }
    return gain(blockEnergies: blocks, peak: peak)
  }

  static func gain(blockEnergies: [Double], peak: Double) -> Float {
    guard peak.isFinite, peak > 0, let strongest = blockEnergies.max(), strongest.isFinite else { return 0 }
    // Exclude near-silence and blocks over 20 dB below the loudest block. This
    // is an energy gate, not a claim of speech/noise classification.
    let active = blockEnergies.filter { $0.isFinite && $0 > max(pow(10, -5.5), strongest * 0.01) }
    guard active.count >= 3 else { return 0 }
    let activeDB = 10 * log10(active.reduce(0, +) / Double(active.count))
    let peakDB = 20 * log10(peak)
    // -24 dBFS active RMS, at most +18 dB, and -3 dBFS sample-peak headroom.
    // Do not turn already-loud recordings down or amplify digital silence.
    return Float(max(0, min(18, -24 - activeDB, -3 - peakDB)))
  }
}
