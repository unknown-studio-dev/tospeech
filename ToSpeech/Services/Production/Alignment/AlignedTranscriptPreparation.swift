import Foundation

struct WordAlignmentEvidence: Codable, Equatable, Sendable {
  let provenance: TranscriptionProvenance
  let alignedWordIDs: [String]
  let policy: String
}

enum AlignedTranscriptPreparation {
  static func prepare(_ segments: [PreparedLessonSegment], audioURL: URL, sampleRate: Int,
    aligner: any WordAlignmentAdapter
  ) async throws -> [PreparedLessonSegment] {
    guard sampleRate > 0 else { throw WordAlignmentError.invalidAudio }
    let tokens = try segments.map { try JSONDecoder().decode([TranscriptWordToken].self, from: Data($0.tokensJSON.utf8)) }
    let words = zip(segments, tokens).flatMap { segment, words in
      words.map { TimedWord(text: $0.text,
        start: Double($0.startFrame ?? segment.startFrame) / Double(sampleRate),
        end: Double($0.endFrame ?? segment.endFrame) / Double(sampleRate)) }
    }
    let result = try await aligner.align(.init(audioURL: audioURL, words: words,
      sentenceStartIndices: sentenceStarts(counts: tokens.map(\.count))))
    guard result.words.count == words.count else { throw WordAlignmentError.invalidOutput }
    try Task.checkCancellation()
    var cursor = 0
    return try zip(segments, tokens).map { segment, old in
      defer { cursor += old.count }
      let proposed = Array(result.words[cursor..<(cursor + old.count)])
      let bounds = expandedBounds(proposed, start: segment.startFrame, end: segment.endFrame, sampleRate: sampleRate)
      let updated = apply(proposed, to: old, sampleRate: sampleRate,
        lowerBound: bounds.lowerBound, upperBound: bounds.upperBound)
      var baseline = try JSONDecoder().decode(CaptionBaseline.self, from: Data(segment.baselineJSON.utf8))
      baseline.alignment = WordAlignmentEvidence(provenance: result.provenance,
        alignedWordIDs: updated.accepted, policy: "ctc-v2-sentence-onset")
      return PreparedLessonSegment(id: segment.id, ordinal: segment.ordinal, text: segment.text,
        contentKey: segment.contentKey, referenceKey: segment.referenceKey,
        startFrame: bounds.lowerBound, endFrame: bounds.upperBound,
        tokensJSON: String(decoding: try JSONEncoder().encode(updated.tokens), as: UTF8.self),
        baselineJSON: String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self))
    }
  }

  static func sentenceStarts(counts: [Int]) -> Set<Int> {
    var offset = 0
    var result: Set<Int> = []
    for count in counts {
      if count > 0 { result.insert(offset) }
      offset += count
    }
    return result
  }

  static func expandedBounds(_ words: [TimedWord?], start: Int, end: Int, sampleRate: Int) -> Range<Int> {
    let valid = words.compactMap { $0 }.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < Double(Int.max / max(1, sampleRate)) }
    let lower = min(start, Int(((valid.map(\.start).min() ?? Double(start) / Double(sampleRate)) * Double(sampleRate)).rounded()))
    let upper = max(end, Int(((valid.map(\.end).max() ?? Double(end) / Double(sampleRate)) * Double(sampleRate)).rounded()))
    return lower..<upper
  }

  static func apply(_ aligned: [TimedWord?], to tokens: [TranscriptWordToken], sampleRate: Int,
    lowerBound: Int, upperBound: Int
  ) -> (tokens: [TranscriptWordToken], accepted: [String]) {
    guard aligned.count == tokens.count, sampleRate > 0 else { return (tokens, []) }
    var accepted: [String] = []
    var result = zip(tokens, aligned).map { token, word in
      guard let word, word.text == token.text, word.start.isFinite, word.end.isFinite,
        word.start >= Double(lowerBound) / Double(sampleRate),
        word.end <= Double(upperBound) / Double(sampleRate), word.end > word.start else {
          return TranscriptWordToken(id: token.id, text: token.text, startFrame: token.startFrame,
            endFrame: token.endFrame, needsTimingReview: IPAFormatting.isPronounceable(token.text) || token.needsTimingReview)
        }
      let start = Int((word.start * Double(sampleRate)).rounded())
      let end = Int((word.end * Double(sampleRate)).rounded())
      guard end > start else { return token }
      accepted.append(token.id)
      return TranscriptWordToken(id: token.id, text: token.text, startFrame: start, endFrame: end,
        needsTimingReview: token.needsTimingReview)
    }
    // Mixing a rejected word's old ASR interval with a newly aligned neighbour
    // must not introduce an overlap. Revert the connected conflicting updates;
    // existing overlaps remain visible for review, never silently split in half.
    var reverted = true
    while reverted {
      reverted = false
      for index in result.indices.dropLast() {
        guard let end = result[index].endFrame, let start = result[index + 1].startFrame, end > start else { continue }
        for affected in [index, index + 1] where accepted.contains(result[affected].id) {
          accepted.removeAll { $0 == result[affected].id }
          let original = tokens[affected]
          result[affected] = TranscriptWordToken(id: original.id, text: original.text,
            startFrame: original.startFrame, endFrame: original.endFrame, needsTimingReview: true)
          reverted = true
        }
      }
    }
    return (result, accepted)
  }
}

@MainActor
protocol WordTimingPreparing {
  func prepare(sentences: [ProductionPreparedSentence], localeIdentifier: String) async throws -> Bool
}

@MainActor
final class AlignedWordTimingPreparer: WordTimingPreparing {
  private let service: ProductionPracticeService
  private let aligner: any WordAlignmentAdapter
  init(service: ProductionPracticeService, aligner: any WordAlignmentAdapter) {
    self.service = service
    self.aligner = aligner
  }

  func prepare(sentences: [ProductionPreparedSentence], localeIdentifier: String) async throws -> Bool {
    let eligible = sentences.filter { !$0.hasManualTiming }.map { sentence in
      guard sentence.baseline.alignment != nil, let original = sentence.baseline.originalTokens,
        original.map(\.id) == sentence.tokens.map(\.id), original.map(\.text) == sentence.tokens.map(\.text) else { return sentence }
      // Re-runs use stable ASR anchors, not successively shifted alignment output.
      return ProductionPreparedSentence(target: sentence.target, revision: sentence.revision,
        tokens: original, baseline: sentence.baseline, annotations: sentence.annotations)
    }
    guard let first = eligible.first else { return false }
    guard eligible.allSatisfy({ $0.target.audioAssetID == first.target.audioAssetID && $0.target.sampleRate == first.target.sampleRate })
    else { throw WordAlignmentError.invalidAudio }
    let currentByID = Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, $0) })
    let rate = first.target.sampleRate
    let words = eligible.flatMap { sentence in
      sentence.tokens.map { TimedWord(text: $0.text,
        start: Double($0.startFrame ?? sentence.target.startFrame) / Double(rate),
        end: Double($0.endFrame ?? sentence.target.endFrame) / Double(rate)) }
    }
    let result = try await aligner.align(.init(audioURL: first.target.audioURL, words: words,
      sentenceStartIndices: AlignedTranscriptPreparation.sentenceStarts(counts: eligible.map { $0.tokens.count })))
    guard result.words.count == words.count else { throw WordAlignmentError.invalidOutput }
    try Task.checkCancellation()
    var cursor = 0
    var changed = false
    for sentence in eligible {
      defer { cursor += sentence.tokens.count }
      try Task.checkCancellation()
      let proposed = Array(result.words[cursor..<(cursor + sentence.tokens.count)])
      let bounds = AlignedTranscriptPreparation.expandedBounds(proposed, start: sentence.target.startFrame,
        end: sentence.target.endFrame, sampleRate: rate)
      let updated = AlignedTranscriptPreparation.apply(proposed, to: sentence.tokens, sampleRate: rate,
        lowerBound: bounds.lowerBound, upperBound: bounds.upperBound)
      guard updated.tokens != currentByID[sentence.id]?.tokens else { continue }
      _ = try await service.publishTimingRevision(.init(segmentID: sentence.target.segmentID,
        expectedRevisionID: sentence.id, startFrame: bounds.lowerBound, endFrame: bounds.upperBound,
        tokens: updated.tokens, resolvesTimingReview: false, timingTranscription: result.provenance,
        alignment: WordAlignmentEvidence(provenance: result.provenance, alignedWordIDs: updated.accepted, policy: "ctc-v2-sentence-onset")))
      changed = true
    }
    return changed
  }
}
