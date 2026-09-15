import Foundation

struct WordAlignmentRequest: Sendable {
  let audioURL: URL
  let words: [TimedWord]
  var sentenceStartIndices: Set<Int> = []
}

struct WordAlignmentResult: Codable, Sendable {
  /// Same count/order as the requested words. Nil means unsupported/uncertain.
  let words: [TimedWord?]
  let provenance: TranscriptionProvenance
}

protocol WordAlignmentAdapter: Sendable {
  func align(_ request: WordAlignmentRequest) async throws -> WordAlignmentResult
}

enum WordAlignmentError: Error, LocalizedError {
  case modelUnavailable, invalidAudio, invalidOutput, busy
  var localizationKey: String {
    switch self {
    case .modelUnavailable: "alignment.error.model_unavailable"
    case .invalidAudio: "alignment.error.audio"
    case .invalidOutput: "alignment.error.output"
    case .busy: "alignment.error.busy"
    }
  }
  var errorDescription: String? {
    switch self {
    case .modelUnavailable: "The local word-alignment model is unavailable. Reinstall the app to restore it."
    case .invalidAudio: "The source audio could not be decoded for word alignment."
    case .invalidOutput: "The alignment model returned invalid acoustic data."
    case .busy: "Word alignment is already running. Try again when it finishes."
    }
  }
}
