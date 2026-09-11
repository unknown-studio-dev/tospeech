import FluidAudio
import Foundation
import Testing
@testable import EchoLab

struct TranscriptionAdapterTests {
  @Test func subwordTokensBecomeWordsWithoutInventedTiming() {
    let pieces = [
      TokenTiming(token: "▁Sha", tokenId: 1, startTime: 1, endTime: 1.1, confidence: 0.8),
      TokenTiming(token: "dowing", tokenId: 2, startTime: 1.1, endTime: 1.4, confidence: 0.8),
      TokenTiming(token: ".", tokenId: 3, startTime: 1.4, endTime: 1.4, confidence: 0.8),
      TokenTiming(token: "▁Hello", tokenId: 4, startTime: 2, endTime: 2.4, confidence: 0.8)
    ]
    let words = ParakeetTranscriptionAdapter.words(from: pieces)
    #expect(words == [TimedWord(text: "Shadowing.", start: 1, end: 1.4), TimedWord(text: "Hello", start: 2, end: 2.4)])
  }

  @Test func parakeetWithoutOtherSourcesRetainsProvenanceAndExcludesOutOfRangeTail() throws {
    let primary = AudioTranscription(words: [
      TimedWord(text: "Hello", start: 0, end: 0.4), TimedWord(text: "world.", start: 0.5, end: 1),
      TimedWord(text: "Thanks.", start: 4, end: 5)
    ], source: .parakeet, provenance: TranscriptionProvenance(engine: "FluidAudio",
      model: TranscriptionSelection.parakeet.modelID, localeIdentifier: "en", runtimeVersion: "test"))
    let segments = try CombinedTranscriptPreparation.prepare(primary: primary, apple: nil,
      captions: [], captionSource: nil, sampleRate: 1000, frameCount: 2000)
    #expect(segments.map(\.text) == ["Hello world."])
    let baseline = try JSONDecoder().decode(CaptionBaseline.self, from: Data(segments[0].baselineJSON.utf8))
    #expect(baseline.source == .parakeet)
    #expect(baseline.transcription?.engine == "FluidAudio")
    #expect(baseline.reconciliation?.primary?.model == TranscriptionSelection.parakeet.modelID)
    #expect(baseline.reconciliation?.whisperModel == nil)
    #expect(baseline.reconciliation?.words.first?.whisperText == nil)
    #expect(baseline.reconciliation?.words.first?.primaryText == "Hello")
    #expect(baseline.reconciliation?.words.first?.timingSource == .parakeet)
    #expect(baseline.reconciliation?.excludedWords?.map(\.text) == ["Thanks."])
    #expect(baseline.reconciliation?.excludedWhisperWords == nil)
    #expect(baseline.reconciliation?.secondaryUnavailable == true)
    #expect(baseline.originalTokens?.first?.endFrame == 400)
  }

  @Test func unknownAdapterDoesNotSelectAnotherEngine() {
    #expect(throws: TranscriptionAdapterError.self) {
      try TranscriptionAdapterRegistry([]).adapter(for: .parakeet)
    }
  }

  @Test func switchingEnginePreservesWhisperPreferenceAndOldSnapshots() throws {
    var preferences = Preferences()
    preferences.activeTranscriptionModel = "large"
    preferences.transcriptionEngine = "whisper"
    preferences.compareTranscriptWithApple = false
    preferences.transcriptionEngine = "parakeet"
    let data = try JSONEncoder().encode(preferences)
    let restored = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(restored.transcriptionEngine == "parakeet")
    #expect(restored.activeTranscriptionModel == "large")
    #expect(!restored.compareTranscriptWithApple)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "transcriptionEngineID")
    old.removeValue(forKey: "appleTranscriptComparison")
    let legacy = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.transcriptionEngine == "parakeet")
    #expect(legacy.activeTranscriptionModel == "large")
  }
}
