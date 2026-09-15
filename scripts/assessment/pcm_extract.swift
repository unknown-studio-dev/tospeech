import AVFAudio
import Foundation
enum WordAlignmentError: Error { case invalidAudio }
enum CoreMLWordAligner {
  nonisolated static func samples(file: AVAudioFile, start: Double, end: Double) throws -> [Float] {
    let format = file.processingFormat
    let startFrame = AVAudioFramePosition((start * format.sampleRate).rounded())
    let count = AVAudioFrameCount(min(file.length - startFrame, AVAudioFramePosition(((end - start) * format.sampleRate).rounded())))
    guard count > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
      let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
      let converter = AVAudioConverter(from: format, to: destinationFormat)
    else { throw WordAlignmentError.invalidAudio }
    file.framePosition = startFrame
    // A decoder may deliver fewer frames than requested even before EOF.
    guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(4096, count)) else { throw WordAlignmentError.invalidAudio }
    var read: AVAudioFrameCount = 0
    while read < count {
      try file.read(into: chunk, frameCount: min(chunk.frameCapacity, count-read))
      guard chunk.frameLength > 0 else { throw WordAlignmentError.invalidAudio }
      let input = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
      let destination = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
      let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
      for index in input.indices {
        guard let from = input[index].mData, let to = destination[index].mData else { throw WordAlignmentError.invalidAudio }
        memcpy(to.advanced(by: Int(read)*bytesPerFrame), from, Int(chunk.frameLength)*bytesPerFrame)
      }
      read += chunk.frameLength
    }
    source.frameLength = read
    guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 4096) else { throw WordAlignmentError.invalidAudio }
    let inputSource = ConversionInput(source)
    var samples: [Float] = []
    let expectedCount = Int(ceil(Double(source.frameLength) * 16000 / format.sampleRate))
    // AVAudioConverter may return .haveData before its buffered tail is drained.
    // Keep pulling until endOfStream instead of treating the first block as the clip.
    for _ in 0..<(expectedCount/4096 + 32) {
      output.frameLength = 0
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { requested, status in
        inputSource.pull(requested: requested, status)
      }
      if let error { throw error }
      guard let channel = output.floatChannelData?[0] else { throw WordAlignmentError.invalidAudio }
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
      if status == .endOfStream {
        guard abs(samples.count-expectedCount) <= 2 else { throw WordAlignmentError.invalidAudio }
        return samples
      }
      guard status != .error, output.frameLength > 0 || status == .inputRanDry else { throw WordAlignmentError.invalidAudio }
    }
    throw WordAlignmentError.invalidAudio
  }
}

/// AVAudioConverter pulls synchronously; the lock also makes the callback safe
/// under the SDK's Sendable contract. The buffer never escapes conversion.
private final class ConversionInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var position: AVAudioFrameCount = 0
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func pull(requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard position < buffer.frameLength, requested > 0 else { status.pointee = .endOfStream; return nil }
    let count = min(requested, buffer.frameLength-position)
    guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
      status.pointee = .noDataNow; return nil
    }
    chunk.frameLength = count
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    for index in source.indices {
      guard let from = source[index].mData, let to = destination[index].mData else {
        status.pointee = .noDataNow; return nil
      }
      memcpy(to, from.advanced(by: Int(position)*bytesPerFrame), Int(count)*bytesPerFrame)
    }
    position += count
    status.pointee = .haveData
    return chunk
  }
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
let values = try CoreMLWordAligner.samples(file: file, start: Double(CommandLine.arguments[3])!, end: Double(CommandLine.arguments[4])!)
try values.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
