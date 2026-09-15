import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite("Reference delivery track")
struct ReferenceDeliveryTrackTests {
  @Test("Precomputes a track for the sentence span from source audio")
  func precompute() throws {
    // Write a 1s 16kHz mono sine fixture.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    // AVAudioFile only finalizes the WAV header on dealloc, so the writer must
    // leave scope before a second handle reads the same path (see PhoneScorerTests).
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
      buf.frameLength = 16_000
      for i in 0..<16_000 { buf.floatChannelData![0][i] = Float(sin(2 * .pi * 180 * Double(i) / 16_000)) * 0.5 }
      try file.write(from: buf)
    }

    let target = ProductionPracticeTarget(
      lessonID: UUID(), lessonGeneration: 1, segmentID: UUID(), segmentRevisionID: UUID(),
      audioAssetID: UUID(), audioURL: url, sampleRate: 16_000, startFrame: 0, endFrame: 12_000,
      text: "test", scope: .sentence, wordIDs: [])
    let track = try ProductionPracticeController.referenceTrack(target: target)
    #expect(track.pitchFrames >= 8)
  }
}
