import AVFAudio
import CryptoKit
import Foundation

struct RecordingTrimPlan: Codable, Equatable, Sendable {
  let originalFrames: Int
  let sampleRate: Int
  let startFrame: Int
  let endFrame: Int
  var frameCount: Int { endFrame - startFrame }
}

struct RecordingTrimReceipt: Codable, Sendable {
  let policy: String
  let originalChecksum: String
  let checksum: String
  let plan: RecordingTrimPlan
}

/// Edge-only energy trimming. It never closes internal pauses or uses source
/// timestamps. Small margins protect weak onsets/releases around detected audio.
enum RecordingSilenceTrimmer {
  static let policy = "edge-energy-10ms-pad80-120-v1"
  static func receiptURL(for final: URL) -> URL { final.appendingPathExtension("trim.json") }

  static func plan(url: URL, skip: Bool = false) throws -> RecordingTrimPlan {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat, rate = Int(file.processingFormat.sampleRate)
    guard (8_000...192_000).contains(rate), (1...8).contains(format.channelCount),
      file.length > 0, Double(file.length)/Double(rate) <= 120 else {
      throw ProductionPracticeError.captureWrite("Invalid audio for silence trimming.")
    }
    let full = RecordingTrimPlan(originalFrames: Int(file.length), sampleRate: rate,
      startFrame: 0, endFrame: Int(file.length))
    if skip { return full }
    let hop = max(1, rate / 100)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(hop)) else {
      throw ProductionPracticeError.captureWrite("Cannot read recording edges.")
    }
    var levels: [Double] = []
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: buffer)
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
        throw ProductionPracticeError.captureWrite("Cannot read recording edges.")
      }
      var energy = 0.0
      for channel in 0..<Int(format.channelCount) {
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) {
          let value = Double(channels[channel][i])
          guard value.isFinite else { throw ProductionPracticeError.captureWrite("Invalid recording samples.") }
          sum += value * value
        }
        energy = max(energy, sum / Double(buffer.frameLength))
      }
      levels.append(10 * log10(max(1e-12, energy)))
    }
    return bounds(levels: levels, full: full, hop: hop)
  }

  static func bounds(levels: [Double], full: RecordingTrimPlan, hop: Int) -> RecordingTrimPlan {
    guard levels.count >= 3, let peak = levels.max(), peak > -55 else { return full }
    let sorted = levels.sorted(), floor = sorted[sorted.count / 5]
    let threshold = max(-65, min(-35, floor + 9), peak - 35)
    // Require 20 ms of activity to avoid selecting a single sample/click.
    let active = levels.indices.dropLast().filter { levels[$0] >= threshold && levels[$0 + 1] >= threshold }
    guard let first = active.first, let last = active.last else { return full }
    let start = max(0, first * hop - Int(Double(full.sampleRate) * 0.08))
    let end = min(full.originalFrames, (last + 2) * hop + Int(Double(full.sampleRate) * 0.12))
    guard end - start >= Int(Double(full.sampleRate) * 0.12) else { return full }
    return .init(originalFrames: full.originalFrames, sampleRate: full.sampleRate, startFrame: start, endFrame: end)
  }

  static func write(source: URL, destination: URL, plan: RecordingTrimPlan) throws {
    let input = try AVAudioFile(forReading: source)
    guard input.length == plan.originalFrames, Int(input.processingFormat.sampleRate) == plan.sampleRate,
      plan.startFrame >= 0, plan.endFrame <= plan.originalFrames, plan.frameCount > 0 else {
      throw ProductionPracticeError.captureWrite("Invalid silence trim bounds.")
    }
    if plan.frameCount == plan.originalFrames {
      try FileManager.default.copyItem(at: source, to: destination)
      return
    }
    let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096) else {
      throw ProductionPracticeError.captureWrite("Cannot allocate trimmed recording.")
    }
    input.framePosition = Int64(plan.startFrame)
    var remaining = plan.frameCount
    while remaining > 0 {
      try Task.checkCancellation()
      try input.read(into: buffer, frameCount: UInt32(min(4096, remaining)))
      guard buffer.frameLength > 0 else { throw ProductionPracticeError.captureWrite("Incomplete recording while trimming.") }
      try output.write(from: buffer)
      remaining -= Int(buffer.frameLength)
    }
  }

  /// Receipt is published before the final CAF. Staging remains available until
  /// the DB commit succeeds, making retries/crash recovery deterministic.
  static func publish(_ manifest: TakeCommitManifest) throws -> RecordingTrimReceipt {
    guard manifest.trimPolicy == policy else { throw ProductionPracticeError.recoveryRequired("Unknown recording trim policy.") }
    let handle = manifest.handle, fm = FileManager.default
    let receiptURL = receiptURL(for: handle.finalURL)
    let previous = fm.fileExists(atPath: receiptURL.path)
      ? try JSONDecoder().decode(RecordingTrimReceipt.self, from: Data(contentsOf: receiptURL)) : nil
    if let previous {
      guard previous.policy == policy, previous.originalChecksum == manifest.checksum,
        previous.plan.originalFrames == manifest.frameCount, previous.plan.sampleRate == manifest.sampleRate,
        previous.plan.startFrame >= 0, previous.plan.endFrame <= manifest.frameCount, previous.plan.frameCount > 0
      else { throw ProductionPracticeError.recoveryRequired("Trim receipt conflicts with retained capture.") }
    }
    if fm.fileExists(atPath: handle.finalURL.path) {
      guard let previous, try checksum(handle.finalURL) == previous.checksum else {
        throw ProductionPracticeError.recoveryRequired("Trimmed take conflicts with retained audio.")
      }
      try validateFinal(handle.finalURL, plan: previous.plan)
      return previous
    }
    guard try checksum(handle.stagingURL) == manifest.checksum else {
      throw ProductionPracticeError.recoveryRequired("Retained capture checksum changed.")
    }
    let selected = try previous?.plan ?? plan(url: handle.stagingURL, skip: manifest.outcome == .noSpeech)
    guard selected.originalFrames == manifest.frameCount, selected.sampleRate == manifest.sampleRate else {
      throw ProductionPracticeError.recoveryRequired("Retained capture metadata changed.")
    }
    let temporary = handle.stagingURL.deletingLastPathComponent().appendingPathComponent("trim-\(UUID()).caf")
    defer { try? fm.removeItem(at: temporary) }
    try write(source: handle.stagingURL, destination: temporary, plan: selected)
    try validateFinal(temporary, plan: selected)
    let result = RecordingTrimReceipt(policy: policy, originalChecksum: manifest.checksum,
      checksum: try checksum(temporary), plan: selected)
    if let previous, previous.checksum != result.checksum {
      throw ProductionPracticeError.recoveryRequired("Trimmed take changed during recovery.")
    }
    try JSONEncoder().encode(result).write(to: receiptURL, options: .atomic)
    try fm.moveItem(at: temporary, to: handle.finalURL)
    return result
  }

  private static func validateFinal(_ url: URL, plan: RecordingTrimPlan) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.length == plan.frameCount, Int(file.processingFormat.sampleRate) == plan.sampleRate else {
      throw ProductionPracticeError.recoveryRequired("Trimmed audio length does not match its receipt.")
    }
  }

  static func checksum(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
