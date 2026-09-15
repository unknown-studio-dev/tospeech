#if DEBUG
import Foundation

/// Presentation-only evidence; never inserted into the production database.
enum ContentMatchingFixtures {
  static func job(status: ContentMatchingJob.Status, exact: Bool = false) throws -> ContentMatchingJob {
    let target = ProductionPracticeTargetSnapshot(lessonID: UUID(), lessonGeneration: 1,
      segmentID: UUID(), segmentRevisionID: UUID(), audioAssetID: UUID(), sampleRate: 16_000,
      startFrame: 0, endFrame: 64_000, text: "I never thought it would make such a difference.",
      scope: .sentence, wordIDs: [])
    let provenance = TranscriptionProvenance(engine: "Preview ASR", model: "Preview model",
      localeIdentifier: "en", runtimeVersion: "Presentation fixture")
    let text = exact ? target.text : "I thought it would make a difference difference"
    let transcription = AudioTranscription(words: [TimedWord(text: text, start: 0, end: 4)],
      source: .parakeet, provenance: provenance)
    return ContentMatchingJob(id: UUID(), takeID: UUID(), target: target,
      selection: .parakeet, locale: "en-GB", provenance: provenance, audioChecksum: "fixture",
      createdAt: Date(), policy: "asr-word-edit-v1", status: status,
      transcription: status == .complete ? transcription : nil,
      match: status == .complete ? try ContentMatch.compare(expected: target.text, observed: text) : nil,
      error: status == .failed ? "The selected model is not installed" : nil,
      errorLocalizationKey: status == .failed ? "matching.model_missing" : nil)
  }
}
#endif
