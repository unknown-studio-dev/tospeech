import Foundation

/// Stored with the caption asset: raw outputs remain available for auditing the merge.
struct CombinedTranscriptArchive: Codable, Sendable {
  let version: Int
  let captionSource: TranscriptSource?
  let captions: [CaptionCue]
  let whisperModel: String?
  let whisperWords: [TimedWord]
  let apple: AudioTranscription?
  var primary: AudioTranscription? = nil
  var appleFailure: String? = nil
}

struct CombinedWordDecision: Codable, Equatable, Sendable {
  let whisperText: String?
  var primaryText: String? = nil
  let appleText: String?
  let selectedText: String
  let textSource: TranscriptSource
  let timingSource: TranscriptSource
  let reviewReason: String?
}

struct CombinedTranscriptEvidence: Codable, Equatable, Sendable {
  let policy: String
  let whisperModel: String?
  let apple: TranscriptionProvenance?
  let captionSource: TranscriptSource?
  let words: [CombinedWordDecision]
  var needsReview: Bool
  var excludedWhisperWords: [TimedWord]? = nil
  var primary: TranscriptionProvenance? = nil
  var excludedWords: [TimedWord]? = nil
  var secondaryUnavailable: Bool? = nil
}

/// The selected ASR covers the full audio. Captions are time-scoped evidence, never a
/// replacement for uncaptained intros/outros. Apple checks words and timings;
/// a substitution needs caption support and matching neighbours on both sides.
/// This is a conservative heuristic, not a confidence score or forced aligner.
enum CombinedTranscriptPreparation {
  static func prepare(
    whisper: [TimedWord], variant: WhisperModelVariant, apple: AudioTranscription,
    captions: [CaptionCue], captionSource: TranscriptSource?, sampleRate: Int, frameCount: Int
  ) throws -> [PreparedLessonSegment] {
    let primary = AudioTranscription(words: whisper, source: .whisper,
      provenance: TranscriptionProvenance(engine: "WhisperKit", model: variant.whisperKitModel,
        localeIdentifier: "en", runtimeVersion: "WhisperKit 1.1.0"))
    return try prepare(primary: primary, apple: apple, captions: captions,
      captionSource: captionSource, sampleRate: sampleRate, frameCount: frameCount)
  }

  static func prepare(
    primary: AudioTranscription, apple: AudioTranscription?,
    captions: [CaptionCue], captionSource: TranscriptSource?, sampleRate: Int, frameCount: Int
  ) throws -> [PreparedLessonSegment] {
    guard !primary.words.isEmpty else { throw TranscriptionAdapterError.emptyTranscript }
    let provenance = primary.provenance
    guard sampleRate > 0, frameCount > 0 else { throw CaptionTranscriptError.invalidAudioTimeline }
    var reconciled: [ReconciledCue] = []
    for cue in NaturalSentenceSegmenter.segment(primary.words) {
      try Task.checkCancellation()
      let base = (cue.words ?? []).map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
      let candidates = (apple?.words ?? []).filter { $0.end > cue.start - 0.5 && $0.start < cue.end + 0.5 }
      // Bound alignment memory even for unpunctuated, hours-long inputs.
      let bounded = base.count <= 256 && candidates.count <= 512
      let aligned = bounded ? TranscriptAligner.align(reference: base.map(\.text), timed: candidates) : []
      var decisions: [CombinedWordDecision] = []
      var words: [CaptionWord] = []
      var needsReview = !bounded || apple == nil
      for (index, word) in base.enumerated() {
        let match = bounded ? aligned[index] : nil
        let spoken = IPAFormatting.isPronounceable(word.text)
        let nearby = match.map {
          abs(($0.start ?? -.infinity) - word.start) <= 0.75
        } ?? false
        let agrees = match?.isMatched == true && nearby
        let start = match?.start ?? word.start
        let end = match?.end ?? word.end
        let validApple = start.isFinite && end.isFinite && end > start && start >= 0
        let validWhisper = word.start.isFinite && word.end.isFinite && word.end > word.start && word.start >= 0
        var text = word.text
        var textSource = primary.source
        var timingSource = primary.source
        var chosenStart = word.start
        var chosenEnd = word.end
        var reason: String? = spoken && apple != nil && !agrees ? "asr_text_disagreement" : nil
        if !agrees, nearby, validApple, let alternative = match?.candidateText,
          index > 0, index + 1 < aligned.count,
          aligned[index - 1].isMatched, aligned[index + 1].isMatched,
          captionSupports(alternative, excluding: word.text, start: start, end: end, captions: captions)
        {
          text = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
          textSource = .appleSpeechAnalyzer
          chosenStart = start
          chosenEnd = end
          timingSource = .appleSpeechAnalyzer
          // Preserve a visible review marker even when two sources support a correction.
          reason = "caption_apple_correction"
        } else if agrees && validApple {
          if !validWhisper {
            chosenStart = start
            chosenEnd = end
            timingSource = .appleSpeechAnalyzer
          } else if abs(start - word.start) > 0.35 || abs(end - word.end) > 0.35 {
            reason = "asr_timing_disagreement"
          }
        }
        if spoken {
          let reference = captions.filter { $0.end > word.start && $0.start < word.end }
          if !reference.isEmpty && !reference.contains(where: {
            $0.text.split(whereSeparator: \.isWhitespace).contains { normalize(String($0)) == normalize(text) }
          }) { reason = "caption_asr_disagreement" }
        }
        if spoken && (!chosenStart.isFinite || !chosenEnd.isFinite || chosenEnd <= chosenStart) {
          reason = "missing_word_timing"
        }
        needsReview = needsReview || reason != nil
        words.append(CaptionWord(text: text, start: chosenStart, end: chosenEnd, needsReview: reason != nil))
        decisions.append(CombinedWordDecision(
          whisperText: primary.source == .whisper ? word.text : nil, primaryText: word.text, appleText: match?.candidateText, selectedText: text,
          textSource: textSource, timingSource: timingSource, reviewReason: reason))
      }
      // Insertions in Apple's stream are also disagreements; don't silently claim agreement.
      let interiorApple = candidates.filter { $0.start >= cue.start && $0.end <= cue.end }
      if bounded && TranscriptAligner.align(reference: interiorApple.map(\.text), timed: base)
        .contains(where: { !$0.isMatched && IPAFormatting.isPronounceable($0.text) }) {
        needsReview = true
      }
      let scopedCaptions = captions.filter { $0.end > cue.start && $0.start < cue.end }
      let finiteStarts = words.map(\.start).filter(\.isFinite)
      let finiteEnds = words.map(\.end).filter(\.isFinite)
      let merged = CaptionCue(
        start: min(cue.start, finiteStarts.min() ?? cue.start),
        end: max(cue.end, finiteEnds.max() ?? cue.end),
        text: TranscriptText.join(words.map(\.text)), words: words,
        timingReviewReason: needsReview ? "combined_transcript_review" : nil)
      let evidence = CombinedTranscriptEvidence(
        policy: "youtube-primary-apple-v2", whisperModel: primary.source == .whisper ? provenance.model : nil,
        apple: apple?.provenance, captionSource: scopedCaptions.isEmpty ? nil : captionSource,
        words: decisions, needsReview: needsReview, primary: provenance, secondaryUnavailable: apple == nil)
      reconciled.append(ReconciledCue(cue: merged, evidence: evidence))
    }
    var output: [PreparedLessonSegment] = []
    for item in usableCues(reconciled, duration: Double(frameCount) / Double(sampleRate)) {
      let built = try CaptionTranscriptBuilder.build(
        cues: [item.cue], source: primary.source, sampleRate: sampleRate, frameCount: frameCount,
        provenance: provenance, ordinalOffset: output.count)
      guard let segment = built.first else { continue }
      var baseline = try JSONDecoder().decode(CaptionBaseline.self, from: Data(segment.baselineJSON.utf8))
      baseline.reconciliation = item.evidence
      output.append(PreparedLessonSegment(
        id: segment.id, ordinal: output.count, text: segment.text, contentKey: segment.contentKey,
        referenceKey: segment.referenceKey, startFrame: segment.startFrame, endFrame: segment.endFrame,
        tokensJSON: segment.tokensJSON,
        baselineJSON: String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self)))
    }
    guard !output.isEmpty else { throw TranscriptPreparationError.noTimedSentences }
    return output
  }

  private struct ReconciledCue {
    let cue: CaptionCue
    let evidence: CombinedTranscriptEvidence
  }

  /// A zero-duration ASR sentence must not abort all valid sentences before it.
  /// Keep its words, untimed and marked for review, in an adjacent playable
  /// context. Never manufacture a word interval or a standalone one-frame clip.
  private static func usableCues(_ input: [ReconciledCue], duration: Double) -> [ReconciledCue] {
    var output: [ReconciledCue] = []
    var leading: [ReconciledCue] = []
    var excluded: [TimedWord] = []
    for item in input {
      guard IPAFormatting.isPronounceable(item.cue.text) else { continue }
      let cue = item.cue
      if cue.start.isFinite && cue.end.isFinite && (cue.start >= duration || cue.end <= 0) {
        excluded.append(contentsOf: (cue.words ?? []).map { TimedWord(text: $0.text, start: $0.start, end: $0.end) })
        continue
      }
      let usable = cue.start.isFinite && cue.end.isFinite && cue.end > cue.start && cue.end > 0 && cue.start < duration
      if usable {
        var anchored = item
        for prefix in leading.reversed() { anchored = attach(prefix, to: anchored, before: true) }
        leading.removeAll()
        output.append(anchored)
      } else if let previous = output.popLast() {
        output.append(attach(item, to: previous, before: false))
      } else {
        leading.append(item)
      }
    }
    if !excluded.isEmpty, let last = output.popLast() {
      var evidence = last.evidence
      evidence.needsReview = true
      evidence.excludedWords = excluded
      if evidence.whisperModel != nil { evidence.excludedWhisperWords = excluded }
      output.append(ReconciledCue(cue: CaptionCue(start: last.cue.start, end: last.cue.end, text: last.cue.text,
        words: last.cue.words, timingReviewReason: "asr_outside_audio"), evidence: evidence))
    }
    return output
  }

  private static func attach(_ unlocated: ReconciledCue, to anchor: ReconciledCue, before: Bool) -> ReconciledCue {
    let unlocatedWords = (unlocated.cue.words ?? []).map {
      // Equal bounds explicitly express unknown word timing inside this context.
      CaptionWord(text: $0.text, start: anchor.cue.start, end: anchor.cue.start, needsReview: true)
    }
    let unlocatedDecisions = unlocated.evidence.words.map {
      CombinedWordDecision(whisperText: $0.whisperText, primaryText: $0.primaryText, appleText: $0.appleText, selectedText: $0.selectedText,
        textSource: $0.textSource, timingSource: $0.timingSource, reviewReason: "unusable_sentence_timing")
    }
    let words = before ? unlocatedWords + (anchor.cue.words ?? []) : (anchor.cue.words ?? []) + unlocatedWords
    let decisions = before ? unlocatedDecisions + anchor.evidence.words : anchor.evidence.words + unlocatedDecisions
    return ReconciledCue(
      cue: CaptionCue(start: anchor.cue.start, end: anchor.cue.end, text: TranscriptText.join(words.map(\.text)),
        words: words, timingReviewReason: "unusable_sentence_timing"),
      evidence: CombinedTranscriptEvidence(policy: anchor.evidence.policy, whisperModel: anchor.evidence.whisperModel,
        apple: anchor.evidence.apple, captionSource: anchor.evidence.captionSource ?? unlocated.evidence.captionSource,
        words: decisions, needsReview: true, primary: anchor.evidence.primary,
          secondaryUnavailable: anchor.evidence.secondaryUnavailable))
  }

  private static func captionSupports(
    _ candidate: String, excluding original: String, start: Double, end: Double, captions: [CaptionCue]
  ) -> Bool {
    let nearby = captions.filter { $0.end > start && $0.start < end }
    let tokens = nearby.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) } }
    return !normalize(candidate).isEmpty && tokens.contains(normalize(candidate)) && !tokens.contains(normalize(original))
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
