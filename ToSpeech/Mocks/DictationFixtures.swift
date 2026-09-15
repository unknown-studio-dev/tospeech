#if DEBUG
import Foundation

actor DictationMemoryStorage: DictationStorage {
  var values: [UUID: DictationProgress] = [:]
  var fails = false
  func setFailure(_ value: Bool) { fails = value }
  func dictationProgress(lessonID: UUID) async throws -> [DictationProgress] {
    if fails { throw DictationError.invalidProgress }
    return values.values.filter { $0.lessonID == lessonID }
  }
  func saveDictationProgress(_ value: DictationProgress) async throws {
    if fails { throw DictationError.invalidProgress }
    try value.validate()
    values[value.revisionID] = value
  }
}

@MainActor final class DictationPreviewAudio: DictationAudioPlaying {
  var onFailure: (@MainActor @Sendable (String) -> Void)?
  var state: ProductionAudioPlayer.State = .idle
  var rangeProgress = 0.0
  var completion: (@MainActor @Sendable () -> Void)?
  var played: [ProductionPracticeTarget] = []
  func playSentence(_ target: ProductionPracticeTarget, speed: Double,
    completion: @escaping @MainActor @Sendable () -> Void) throws {
    state = .playing; played.append(target); self.completion = completion
  }
  func finish() { state = .idle; rangeProgress = 1; completion?() }
  func stop() { state = .idle; rangeProgress = 0 }
}

/// In-memory presentation fixtures; never connected to production lessons or storage.
enum DictationFixtures {
  static func sentences() throws -> [ProductionPreparedSentence] {
    let lesson = UUID()
    let texts = ["I never thought it would make such a difference.", "Could you say that again?", "Let's listen carefully."]
    return try texts.enumerated().map { index, text in
      let prepared = try CaptionTranscriptBuilder.build(cues: [.init(start: 0, end: 4, text: text)],
        source: .parakeet, sampleRate: 16_000, frameCount: 64_000)[0]
      let tokens = try JSONDecoder().decode([TranscriptWordToken].self, from: Data(prepared.tokensJSON.utf8))
      let baseline = try JSONDecoder().decode(CaptionBaseline.self, from: Data(prepared.baselineJSON.utf8))
      let revisionID = UUID()
      let phonesUK = ["/aɪ/", "/ˈnevə/", "/θɔːt/", "/ɪt/", "/wʊd/", "/meɪk/", "/sʌtʃ/", "/ə/", "/ˈdɪfrəns/"]
      var annotations: [StoredPreparationAnnotation] = []
      for (wordIndex, token) in tokens.enumerated() where index == 0 {
        for accent in [ReferenceAccent.uk, .us] {
          let phones = [OfflineIPAPronunciation(ipa: phonesUK[wordIndex], source: "Presentation fixture", sourceRevision: "1")]
          if !phones.isEmpty {
            annotations.append(.init(revisionID: revisionID, kind: .ipa,
              lookupKey: "\(token.id):\(accent.rawValue.lowercased())", source: "dictation-fixture",
              automaticValue: try JSONEncoder().encode(IPAAnnotationValue(accent: accent, pronunciations: phones)),
              overrideValue: nil))
          }
        }
      }
      if index == 0 {
        annotations.append(.init(revisionID: revisionID, kind: .translation, lookupKey: "sentence:vi",
          source: "dictation-fixture", automaticValue: try JSONEncoder().encode(SentenceTranslationValue(
            text: "Tôi chưa từng nghĩ điều đó lại tạo ra khác biệt đến vậy.", sourceLanguage: "en", targetLanguage: "vi")),
          overrideValue: nil))
      }
      return ProductionPreparedSentence(target: .init(lessonID: lesson, lessonGeneration: 1,
        segmentID: UUID(), segmentRevisionID: revisionID, audioAssetID: UUID(),
        audioURL: URL(fileURLWithPath: "/dictation-preview-only-\(index).caf"), sampleRate: 16_000,
        startFrame: 0, endFrame: 64_000, text: text, scope: .sentence, wordIDs: []),
        revision: 1, tokens: tokens, baseline: baseline, annotations: annotations)
    }
  }
}
#endif
