import AVFAudio
import Foundation
import OSLog

/// A disposable listening copy. The capture and assessment assets remain immutable.
final class EnhancedRecording: Sendable {
  let url: URL
  let frameCount: Int64
  private let directory: URL
  init(url: URL, frameCount: Int64, directory: URL) {
    self.url = url; self.frameCount = frameCount; self.directory = directory
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}

struct PreparedRecordingAudio: Sendable {
  let url: URL
  let gain: Float
  // Own the temporary file for as long as playback or its cache needs it.
  let enhanced: EnhancedRecording?
}

enum RecordingEnhancementError: LocalizedError {
  case unavailable, invalidAudio, processing
  var errorDescription: String? {
    switch self {
    case .unavailable: "recording.enhance.unavailable"
    case .invalidAudio: "recording.enhance.invalid"
    case .processing: "recording.enhance.failed"
    }
  }
}

enum DeepFilterRecordingRenderer {
  static let policy = "dfn3-0.5.6-atten18-delay1440-v1"

  static func prepare(url: URL, enhance: Bool) async throws -> PreparedRecordingAudio {
    let rendered = enhance ? try await render(url: url) : nil
    let playbackURL = rendered?.url ?? url
    return PreparedRecordingAudio(url: playbackURL,
      gain: try RecordingPlaybackLevel.gain(url: playbackURL), enhanced: rendered)
  }

  /// Processes the complete take before selecting an excerpt, so phoneme clicks
  /// share the same filter history and gain as full-take/A-B/Together playback.
  static func render(url: URL, resources: URL = Bundle.main.resourceURL!) async throws -> EnhancedRecording {
    try Task.checkCancellation()
    let original = try AVAudioFile(forReading: url)
    let format = original.processingFormat
    let rate = format.sampleRate, count = original.length
    guard count > 0, rate.isFinite, (8_000...192_000).contains(rate),
      (1...2).contains(format.channelCount), Double(count) / rate <= 120
    else { throw RecordingEnhancementError.invalidAudio }
    let helper = resources.appendingPathComponent("DeepFilterNet/deep-filter")
    let ffmpeg = resources.appendingPathComponent("Tools/ffmpeg")
    guard [helper, ffmpeg].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw RecordingEnhancementError.unavailable }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tospeech-dfn-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var committed = false
    defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
    let input = directory.appendingPathComponent("take.wav")
    let outputDirectory = directory.appendingPathComponent("filtered", isDirectory: true)
    let output = directory.appendingPathComponent("listening.caf")
    // v0.5.6 ignores incomplete 480-sample hops and -D removes 1440 samples
    // without flushing the tail. Pad full hops + latency before calling it.
    let frames48 = Int(ceil(Double(count) * 48_000 / rate))
    let padded = ((frames48 + 479) / 480) * 480 + 1440
    do {
      try await run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", url.path, "-map", "0:a:0", "-af", "aresample=48000,apad=whole_len=\(padded)",
        "-c:a", "pcm_f32le", input.path], directory: directory)
      try Task.checkCancellation()
      // Pinned release embeds DeepFilterNet3. No runtime/model downloads.
      try await run(helper, ["--compensate-delay", "--atten-lim-db", "18",
        "--output-dir", outputDirectory.path, input.path], directory: directory)
      try Task.checkCancellation()
      try await run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", outputDirectory.appendingPathComponent("take.wav").path,
        "-af", "aresample=\(Int(rate)),atrim=end_sample=\(count)",
        "-c:a", "pcm_f32le", output.path], directory: directory)
      try validate(output, frames: count, rate: rate, channels: format.channelCount)
      try Task.checkCancellation()
      // Keep only the listening copy; intermediate PCM is disposable.
      try FileManager.default.removeItem(at: input)
      try FileManager.default.removeItem(at: outputDirectory)
      committed = true
      return EnhancedRecording(url: output, frameCount: count, directory: directory)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      Logger(subsystem: "com.unknownstudio.tospeech", category: "RecordingEnhancement")
        .error("DeepFilterNet failed: \(String(describing: error), privacy: .public)")
      throw RecordingEnhancementError.processing
    }
  }

  private static func run(_ executable: URL, _ arguments: [String], directory: URL) async throws {
    try Task.checkCancellation()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { _ = try await SubprocessRunner().run(executable: executable,
        arguments: arguments, currentDirectory: directory) }
      group.addTask { try await Task.sleep(for: .seconds(120)); throw RecordingEnhancementError.processing }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  static func validate(_ url: URL, frames: Int64, rate: Double, channels: UInt32) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.length == frames, file.processingFormat.sampleRate == rate,
      file.processingFormat.channelCount == channels,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
    else { throw RecordingEnhancementError.invalidAudio }
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: buffer)
      guard buffer.frameLength > 0, let pcm = buffer.floatChannelData else { throw RecordingEnhancementError.invalidAudio }
      for channel in 0..<Int(channels) {
        guard UnsafeBufferPointer(start: pcm[channel], count: Int(buffer.frameLength)).allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw RecordingEnhancementError.invalidAudio }
      }
    }
  }
}
