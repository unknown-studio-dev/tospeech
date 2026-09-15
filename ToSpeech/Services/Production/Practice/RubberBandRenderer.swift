import AVFAudio
import Foundation

/// Owns a disposable, fully drained render. The player retains one result for repeats.
final class RubberBandRender: Sendable {
  let url: URL
  let frameCount: Int64
  init(url: URL, frameCount: Int64) { self.url = url; self.frameCount = frameCount }
  deinit { try? FileManager.default.removeItem(at: url) }
}

enum RubberBandRenderError: LocalizedError {
  case unsupported, unavailable, invalidAudio, incomplete
  var errorDescription: String? {
    switch self {
    case .unsupported: "playback.r3.unsupported"
    case .unavailable: "playback.r3.unavailable"
    case .invalidAudio: "playback.r3.invalid_audio"
    case .incomplete: "playback.r3.incomplete"
    }
  }
}

/// Rubber Band (GPLv2+) is never linked into the app. The bundled
/// `rubberband-render` helper runs as a separate sandboxed process and the two
/// sides only exchange raw interleaved float PCM files. Only the selected span is
/// decoded; both sides stream in bounded chunks.
enum RubberBandRenderer {
  static let helperRelativePath = "RubberBand/rubberband-render"
  private static let blockFrames = 1024
  private static let outputBlockFrames = 8192

  static func helperURL(resources: URL) -> URL { resources.appendingPathComponent(helperRelativePath) }

  static func isAvailable(resources: URL = Bundle.main.resourceURL!) -> Bool {
    FileManager.default.isExecutableFile(atPath: helperURL(resources: resources).path)
  }

  static func render(url: URL, startFrame: Int, endFrame: Int, speed: Double,
    resources: URL = Bundle.main.resourceURL!) async throws -> RubberBandRender {
    try Task.checkCancellation()
    let input = try AVAudioFile(forReading: url)
    let format = input.processingFormat
    let count = endFrame - startFrame
    guard speed.isFinite, (0.25..<1).contains(speed), startFrame >= 0, count > 0,
      Int64(endFrame) <= input.length, (8_000...192_000).contains(format.sampleRate),
      (1...2).contains(format.channelCount), Double(count) / format.sampleRate <= 120
    else { throw RubberBandRenderError.unsupported }
    let helper = helperURL(resources: resources)
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw RubberBandRenderError.unavailable }

    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("tospeech-r3-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let rawInput = workspace.appendingPathComponent("span.f32")
    let rawOutput = workspace.appendingPathComponent("stretched.f32")
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("tospeech-r3-\(UUID()).caf")
    var committed = false
    defer { if !committed { try? FileManager.default.removeItem(at: destination) } }

    try writeInterleavedSpan(from: input, startFrame: startFrame, count: count, to: rawInput)
    try Task.checkCancellation()
    try await run(helper, [rawInput.path, rawOutput.path, String(Int(format.sampleRate)),
      String(format.channelCount), String(1 / speed), String(count)], directory: workspace)
    try Task.checkCancellation()
    let expected = Int64((Double(count) / speed).rounded())
    let written = try writeCAF(fromInterleaved: rawOutput, format: format, to: destination)
    guard abs(written - expected) <= 1 else { throw RubberBandRenderError.incomplete }
    try Task.checkCancellation()
    committed = true
    return RubberBandRender(url: destination, frameCount: written)
  }

  private static func run(_ executable: URL, _ arguments: [String], directory: URL) async throws {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await SubprocessRunner().run(executable: executable, arguments: arguments, currentDirectory: directory)
        }
        group.addTask { try await Task.sleep(for: .seconds(120)); throw RubberBandRenderError.incomplete }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch let error as SubprocessError {
      switch error {
      case .launch: throw RubberBandRenderError.unavailable
      case .cancelled: throw CancellationError()
      case .unsuccessful(_, let diagnostics):
        throw diagnostics.contains("non-finite input") ? RubberBandRenderError.invalidAudio : RubberBandRenderError.incomplete
      }
    }
  }

  private static func writeInterleavedSpan(from input: AVAudioFile, startFrame: Int, count: Int, to url: URL) throws {
    let format = input.processingFormat
    let channels = Int(format.channelCount)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockFrames)),
      FileManager.default.createFile(atPath: url.path, contents: nil)
    else { throw RubberBandRenderError.invalidAudio }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    input.framePosition = Int64(startFrame)
    var interleaved = [Float](repeating: 0, count: blockFrames * channels)
    var read = 0
    while read < count {
      try Task.checkCancellation()
      try input.read(into: buffer, frameCount: AVAudioFrameCount(min(blockFrames, count - read)))
      let frames = Int(buffer.frameLength)
      guard frames > 0, let pcm = buffer.floatChannelData else { throw RubberBandRenderError.invalidAudio }
      for channel in 0..<channels {
        for frame in 0..<frames {
          let value = pcm[channel][frame]
          guard value.isFinite else { throw RubberBandRenderError.invalidAudio }
          interleaved[frame * channels + channel] = value
        }
      }
      try interleaved.withUnsafeBufferPointer { pointer in
        try handle.write(contentsOf: Data(buffer: UnsafeBufferPointer(rebasing: pointer[..<(frames * channels)])))
      }
      read += frames
    }
  }

  private static func writeCAF(fromInterleaved url: URL, format: AVAudioFormat, to destination: URL) throws -> Int64 {
    let channels = Int(format.channelCount)
    let frameBytes = channels * MemoryLayout<Float>.size
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let file = try AVAudioFile(forWriting: destination, settings: format.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputBlockFrames))
    else { throw RubberBandRenderError.invalidAudio }
    var written: Int64 = 0
    while true {
      try Task.checkCancellation()
      guard let data = try handle.read(upToCount: outputBlockFrames * frameBytes), !data.isEmpty else { break }
      guard data.count % frameBytes == 0, let pcm = buffer.floatChannelData else { throw RubberBandRenderError.invalidAudio }
      let frames = data.count / frameBytes
      let samples = [Float](unsafeUninitializedCapacity: frames * channels) { target, initialized in
        initialized = data.copyBytes(to: target) / MemoryLayout<Float>.size
      }
      guard samples.count == frames * channels, samples.allSatisfy(\.isFinite) else { throw RubberBandRenderError.invalidAudio }
      for frame in 0..<frames {
        for channel in 0..<channels { pcm[channel][frame] = samples[frame * channels + channel] }
      }
      buffer.frameLength = AVAudioFrameCount(frames)
      try file.write(from: buffer)
      written += Int64(frames)
    }
    return written
  }
}
