#if DEBUG
import AVFAudio
import CryptoKit
import Foundation

/// Read-only input probe; exports listening copies in the preview directory.
enum RecordingEnhancementProbe {
  static func trim(url: URL, directory: URL) async throws {
    let directory = directory.appendingPathComponent("RecordingEdgeTrimProbe", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let originalChecksum = try RecordingSilenceTrimmer.checksum(url)
    let plan = try RecordingSilenceTrimmer.plan(url: url)
    let output = directory.appendingPathComponent("recording-edge-trimmed.caf")
    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
    try RecordingSilenceTrimmer.write(source: url, destination: output, plan: plan)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(RecordingTrimReceipt(policy: RecordingSilenceTrimmer.policy,
      originalChecksum: originalChecksum, checksum: RecordingSilenceTrimmer.checksum(output), plan: plan))
      .write(to: directory.appendingPathComponent("recording-trim.json"))
    guard try RecordingSilenceTrimmer.checksum(url) == originalChecksum else {
      throw RecordingEnhancementError.invalidAudio
    }
    try await run(url: output, directory: directory)
    print("RECORDING_TRIM: \(plan.originalFrames) -> \(plan.frameCount) frames; kept \(plan.startFrame)..<\(plan.endFrame)")
  }

  static func run(url: URL, directory: URL) async throws {
    let before = SHA256.hash(data: try Data(contentsOf: url))
    let started = Date()
    let enhanced = try await DeepFilterRecordingRenderer.prepare(url: url, enhance: true)
    let elapsed = Date().timeIntervalSince(started)
    let oldGain = try RecordingPlaybackLevel.gain(url: url)
    var metrics: [String: Any] = [:]
    for (name, input, gain) in [("raw", url, Float(0)), ("gain-only", url, oldGain),
      ("filtered", enhanced.url, Float(0)), ("filtered-boosted", enhanced.url, enhanced.gain)] {
      let source = try AVAudioFile(forReading: input)
      let format = source.processingFormat
      let output = directory.appendingPathComponent("recording-\(name).wav")
      let destination = try AVAudioFile(forWriting: output, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
      let factor = pow(Float(10), gain/20)
      var peak = 0.0, sum = 0.0, count = 0
      while source.framePosition < source.length {
        try source.read(into: buffer)
        for channel in 0..<Int(format.channelCount) {
          for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![channel][frame] *= factor
            let value = Double(buffer.floatChannelData![channel][frame])
            peak = max(peak, abs(value)); sum += value * value; count += 1
          }
        }
        try destination.write(from: buffer)
      }
      metrics[name] = ["frames": source.length, "sampleRate": format.sampleRate,
        "channels": format.channelCount, "gainDB": gain,
        "rmsDBFS": 10 * log10(max(1e-20, sum / Double(count))),
        "peakDBFS": 20 * log10(max(1e-10, peak)), "output": output.path]
    }
    guard before == SHA256.hash(data: try Data(contentsOf: url)) else { throw RecordingEnhancementError.invalidAudio }
    let report: [String: Any] = ["policy": DeepFilterRecordingRenderer.policy,
      "elapsedSeconds": elapsed, "originalUnchanged": true, "variants": metrics]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("recording-enhancement.json"))
    print("RECORDING_ENHANCEMENT: \(elapsed)s, gain \(enhanced.gain)dB, original unchanged")
  }
}
#endif
