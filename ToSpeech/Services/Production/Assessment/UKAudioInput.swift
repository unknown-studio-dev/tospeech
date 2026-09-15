import AVFAudio
import Foundation

/// Shared, bounded PCM decoding. Pitch/VAD keep the original amplitude; only
/// the XLSR branch applies that model's utterance normalization afterward.
enum UKAudioInput {
  static func samples(_ url: URL, span: AudioSpan?) throws -> [Float] {
    try Task.checkCancellation()
    let file = try AVAudioFile(forReading: url)
    let full = Double(file.length)/file.processingFormat.sampleRate
    let start = span?.start ?? 0, end = span?.end ?? full
    guard start.isFinite, end.isFinite, start >= 0, end <= full, end > start else { throw BuddyError.invalidAudio }
    guard end-start <= 30 else { throw BuddyError.tooLong }
    let values = try CoreMLWordAligner.samples(file: file, start: start, end: end)
    guard values.count >= 800, values.count <= 480_000, values.allSatisfy(\.isFinite) else { throw BuddyError.invalidAudio }
    return values
  }
}
