import SwiftUI

/// Production adapters for the already-approved Shadowing sheets. These views
/// intentionally add no parallel layout or visual styling.
struct ProductionWordPronunciationSheet: View {
  let sentence: LessonSentence
  let token: TranscriptWordToken
  let onPreview: () -> Void
  let onEditTiming: () -> Void
  let onClose: () -> Void
  let runtime: WordPronunciationRuntime

  var body: some View {
    WordPronunciationView(
      sentence: sentence, wordID: token.id,
      onEditTiming: { _ in onEditTiming() }, onClose: onClose,
      onPreviewSource: onPreview, usesPreviewReferenceAudio: false, runtime: runtime)
  }
}

struct ProductionTimingEditorSheet: View {
  let lesson: Lesson
  let sentence: LessonSentence
  let wordID: String?
  let onPreview: (AudioSpan, String) -> Void
  let onSave: (LessonSentence) async -> String?
  let waveformSamples: [Double]?
  let isPreparingWaveform: Bool
  let waveformError: String?
  let onRetryWaveform: () -> Void
  let onClose: () -> Void

  var body: some View {
    TimingEditorView(
      lesson: lesson, sentence: sentence, wordID: wordID, onClose: onClose,
      onPreviewSource: onPreview, onSaveDraft: onSave,
      allowsTranscriptEditing: false, allowsTranslationEditing: true,
      waveformSamples: waveformSamples,
      usesSimulatedWaveform: false, isPreparingWaveform: isPreparingWaveform,
      waveformError: waveformError, onRetryWaveform: onRetryWaveform)
  }
}
