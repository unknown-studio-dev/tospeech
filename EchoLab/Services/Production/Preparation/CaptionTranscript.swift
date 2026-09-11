import CryptoKit
import Foundation

/// Records where a transcript came from so later preparation never disguises
/// automatically generated text as creator-supplied captions.
enum TranscriptSource: String, Codable, Sendable {
  case creatorCaption
  case automaticCaption
  case appleSpeech
}

struct CaptionCue: Codable, Equatable, Sendable {
  let start: TimeInterval
  let end: TimeInterval
  let text: String
  let words: [CaptionWord]?
  /// Set only when on-device audio evidence contradicts this caption cue.
  /// Missing evidence never pretends to be a confirmed mismatch.
  let timingReviewReason: String?

  init(
    start: TimeInterval, end: TimeInterval, text: String, words: [CaptionWord]? = nil,
    timingReviewReason: String? = nil
  ) {
    self.start = start
    self.end = end
    self.text = text
    self.words = words
    self.timingReviewReason = timingReviewReason
  }
}

struct CaptionWord: Codable, Equatable, Sendable {
  let text: String
  let start: TimeInterval
  let end: TimeInterval
}

struct TranscriptWordToken: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let startFrame: Int?
  let endFrame: Int?
  let needsTimingReview: Bool
}

struct PreparedLessonSegment: Codable, Equatable, Sendable {
  let id: UUID
  let ordinal: Int
  let text: String
  let contentKey: String
  let referenceKey: String
  let startFrame: Int
  let endFrame: Int
  let tokensJSON: String
  let baselineJSON: String
}

struct PreparedLessonAnnotation: Codable, Equatable, Sendable {
  let segmentID: UUID
  let kind: PreparationAnnotationKind
  let lookupKey: String
  let source: String
  let automaticValue: Data
}

enum PreparationAnnotationKind: String, Codable, Sendable {
  case translation
  case ipa
}

struct StoredPreparationAnnotation: Codable, Equatable, Sendable {
  let revisionID: UUID
  let kind: PreparationAnnotationKind
  let lookupKey: String
  let source: String
  let automaticValue: Data?
  let overrideValue: Data?
}

struct SegmentPreparationTarget: Codable, Equatable, Sendable {
  let revisionID: UUID
  let text: String
  let tokens: [TranscriptWordToken]
}

/// A human-confirmed timing adjustment. Text and token identity are deliberately
/// not editable through this route: it creates a new timing revision for the
/// same transcript sentence rather than quietly changing what was practised.
struct SegmentTimingRevisionDraft: Codable, Equatable, Sendable {
  let segmentID: UUID
  let expectedRevisionID: UUID
  let startFrame: Int
  let endFrame: Int
  let tokens: [TranscriptWordToken]
  /// True only after the editor has reviewed the updated timing. It is never
  /// inferred from a UI opening or a background job.
  let resolvesTimingReview: Bool
}

struct StoredTimingRevision: Codable, Equatable, Sendable {
  let segmentID: UUID
  let previousRevisionID: UUID
  let revisionID: UUID
  let revision: Int
}

struct IPAAnnotationValue: Codable, Equatable, Sendable {
  let accent: ReferenceAccent
  let pronunciations: [OfflineIPAPronunciation]
}

enum CaptionTranscriptError: Error, Equatable, LocalizedError, Sendable {
  case malformedWebVTT
  case noUsableCues
  case invalidAudioTimeline

  var errorDescription: String? {
    switch self {
    case .malformedWebVTT: "The downloaded captions are not valid WebVTT."
    case .noUsableCues: "The captions do not contain usable timed English text."
    case .invalidAudioTimeline: "The source audio timeline is invalid."
    }
  }
}

/// Parses only timed text cues. Styling, NOTE and REGION blocks intentionally
/// never become learner-visible transcript text.
enum WebVTTCaptionParser {
  static func parse(_ source: String) throws -> [CaptionCue] {
    let lines =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") == true
    else {
      throw CaptionTranscriptError.malformedWebVTT
    }

    var cues: [CaptionCue] = []
    var index = 1
    while index < lines.count {
      let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else {
        index += 1
        continue
      }
      if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
        index = skipBlock(lines, from: index + 1)
        continue
      }

      let timingLine: String
      if line.contains("-->") {
        timingLine = line
      } else {
        index += 1
        guard index < lines.count else { break }
        timingLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard let timing = parseTiming(timingLine) else {
        index = skipBlock(lines, from: index + 1)
        continue
      }

      index += 1
      var textLines: [String] = []
      while index < lines.count {
        let text = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { break }
        textLines.append(text)
        index += 1
      }
      let text = sanitize(textLines.joined(separator: " "))
      if !text.isEmpty, timing.end > timing.start {
        cues.append(CaptionCue(start: timing.start, end: timing.end, text: text))
      }
      index = skipBlock(lines, from: index)
    }
    guard !cues.isEmpty else { throw CaptionTranscriptError.noUsableCues }
    return cues
  }

  private static func parseTiming(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
    let parts = line.components(separatedBy: "-->")
    guard parts.count == 2,
      let start = time(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    let endText = parts[1].split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    guard let end = time(endText), end > start else { return nil }
    return (start, end)
  }

  private static func time(_ text: String) -> TimeInterval? {
    let pieces = text.split(separator: ":")
    guard pieces.count == 2 || pieces.count == 3 else { return nil }
    let secondsText = String(pieces.last!).replacingOccurrences(of: ",", with: ".")
    guard let seconds = Double(secondsText), seconds >= 0 else { return nil }
    let minutesIndex = pieces.count == 3 ? 1 : 0
    guard let minutes = Double(pieces[minutesIndex]), minutes >= 0 else { return nil }
    let hours = pieces.count == 3 ? Double(pieces[0]) : 0
    guard let hours, hours >= 0 else { return nil }
    return hours * 3_600 + minutes * 60 + seconds
  }

  private static func skipBlock(_ lines: [String], from index: Int) -> Int {
    var next = index
    while next < lines.count,
      !lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    { next += 1 }
    return next + 1
  }

  private static func sanitize(_ text: String) -> String {
    text
      .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }
}

enum CaptionTranscriptBuilder {
  static func build(
    cues: [CaptionCue], source: TranscriptSource, sampleRate: Int, frameCount: Int
  ) throws -> [PreparedLessonSegment] {
    guard sampleRate > 0, frameCount > 0 else { throw CaptionTranscriptError.invalidAudioTimeline }
    var segments: [PreparedLessonSegment] = []
    for cue in cues {
      let start = max(0, min(frameCount - 1, Int((cue.start * Double(sampleRate)).rounded())))
      let end = max(start + 1, min(frameCount, Int((cue.end * Double(sampleRate)).rounded())))
      guard end > start else { continue }
      let normalized = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else { continue }
      let ordinal = segments.count
      let words = tokens(for: cue, ordinal: ordinal, sampleRate: sampleRate, frameCount: frameCount)
      let hasTrustedWordTiming = words.allSatisfy {
        $0.startFrame != nil && $0.endFrame != nil && !$0.needsTimingReview
      }
      let baseline = CaptionBaseline(
        source: source, cueStartFrame: start, cueEndFrame: end,
        sentenceTimingNeedsReview: cue.timingReviewReason != nil,
        wordTimingNeedsReview: !hasTrustedWordTiming,
        timingReviewReason: cue.timingReviewReason, originalTokens: words)
      let contentKey = hash(normalized.lowercased())
      segments.append(
        PreparedLessonSegment(
          id: UUID(), ordinal: ordinal, text: normalized,
          contentKey: contentKey, referenceKey: "\(source.rawValue):\(contentKey)",
          startFrame: start, endFrame: end,
          tokensJSON: try json(words), baselineJSON: try json(baseline)))
    }
    guard !segments.isEmpty else { throw CaptionTranscriptError.noUsableCues }
    return segments
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private static func tokens(
    for cue: CaptionCue, ordinal: Int, sampleRate: Int, frameCount: Int
  ) -> [TranscriptWordToken] {
    guard let cueWords = cue.words, !cueWords.isEmpty else {
      return cue.text.split(whereSeparator: { $0.isWhitespace }).enumerated().map { index, word in
        TranscriptWordToken(
          id: "caption-\(ordinal)-word-\(index)", text: String(word),
          startFrame: nil, endFrame: nil, needsTimingReview: true)
      }
    }
    return cueWords.enumerated().map { index, word in
      let start = max(0, min(frameCount - 1, Int((word.start * Double(sampleRate)).rounded())))
      let end = max(start + 1, min(frameCount, Int((word.end * Double(sampleRate)).rounded())))
      let valid = word.end > word.start && start >= 0 && end > start && end <= frameCount
      return TranscriptWordToken(
        id: "speech-\(ordinal)-word-\(index)", text: word.text,
        startFrame: valid ? start : nil, endFrame: valid ? end : nil,
        needsTimingReview: !valid)
    }
  }
}

/// Transfers only observed Apple Speech word ranges onto matching caption
/// tokens. The sequence alignment never interpolates or distributes a cue, so
/// an unmatched token stays untimed and visibly requires review.
enum CaptionWordTimingAligner {
  static func enriching(
    captionCues: [CaptionCue], with speechCues: [CaptionCue]
  ) -> [CaptionCue] {
    captionCues.map { cue in
      guard cue.timingReviewReason == nil else { return cue }
      let tokens = cue.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      let aligned = alignedWords(
        for: tokens, cueStart: cue.start, cueEnd: cue.end, speechCues: speechCues)
      guard aligned.count == tokens.count, aligned.allSatisfy({ $0 != nil }) else { return cue }
      return CaptionCue(
        start: cue.start, end: cue.end, text: cue.text,
        words: aligned.compactMap { $0 }, timingReviewReason: nil)
    }
  }

  static func alignedWords(
    for captionTokens: [String], cueStart: TimeInterval, cueEnd: TimeInterval,
    speechCues: [CaptionCue]
  ) -> [CaptionWord?] {
    guard !captionTokens.isEmpty, cueEnd > cueStart else {
      return Array(repeating: nil, count: captionTokens.count)
    }
    var candidates: [CaptionWord] = []
    for speechCue in speechCues {
      for word in speechCue.words ?? []
      where word.start >= cueStart && word.end <= cueEnd && word.end > word.start {
        candidates.append(word)
      }
    }
    candidates.sort { lhs, rhs in
      if lhs.start == rhs.start { return lhs.end < rhs.end }
      return lhs.start < rhs.start
    }
    guard !candidates.isEmpty else {
      return Array(repeating: nil, count: captionTokens.count)
    }

    let left = captionTokens.map(normalized)
    let right = candidates.map { normalized($0.text) }
    var lengths = Array(
      repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
    for leftIndex in 1...left.count {
      for rightIndex in 1...right.count {
        if !left[leftIndex - 1].isEmpty, left[leftIndex - 1] == right[rightIndex - 1] {
          lengths[leftIndex][rightIndex] = lengths[leftIndex - 1][rightIndex - 1] + 1
        } else {
          lengths[leftIndex][rightIndex] = max(
            lengths[leftIndex - 1][rightIndex], lengths[leftIndex][rightIndex - 1])
        }
      }
    }

    var result = [CaptionWord?](repeating: nil, count: captionTokens.count)
    var leftIndex = left.count
    var rightIndex = right.count
    while leftIndex > 0, rightIndex > 0 {
      if !left[leftIndex - 1].isEmpty, left[leftIndex - 1] == right[rightIndex - 1] {
        let evidence = candidates[rightIndex - 1]
        result[leftIndex - 1] = CaptionWord(
          text: captionTokens[leftIndex - 1], start: evidence.start, end: evidence.end)
        leftIndex -= 1
        rightIndex -= 1
      } else if lengths[leftIndex - 1][rightIndex] >= lengths[leftIndex][rightIndex - 1] {
        leftIndex -= 1
      } else {
        rightIndex -= 1
      }
    }
    return result
  }

  private static func normalized(_ text: String) -> String {
    String(
      text.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      })
  }
}

/// Conservative local comparison of downloaded caption text with word timestamps
/// supplied by Apple Speech. It identifies evidence for review; it never repairs
/// timing, invents word spans, or reports a match when no local ASR was available.
enum CaptionAudioMismatchDetector {
  static func markingReview(
    captionCues: [CaptionCue], against speechCues: [CaptionCue]
  ) -> [CaptionCue] {
    captionCues.map { caption in
      guard let reason = reasonForReview(caption: caption, speechCues: speechCues) else {
        return caption
      }
      return CaptionCue(
        start: caption.start, end: caption.end, text: caption.text, words: caption.words,
        timingReviewReason: reason)
    }
  }

  private static func reasonForReview(
    caption: CaptionCue, speechCues: [CaptionCue]
  ) -> String? {
    let candidates = speechCues.filter {
      $0.end > caption.start - 0.75 && $0.start < caption.end + 0.75
    }
    guard !candidates.isEmpty else { return "no_speech_alignment" }
    let best = candidates.max {
      similarity(caption.text, $0.text) < similarity(caption.text, $1.text)
    }
    guard let best else { return "no_speech_alignment" }
    if abs(best.start - caption.start) > 1.25 { return "sentence_start_offset" }
    return similarity(caption.text, best.text) < 0.6 ? "caption_audio_text_mismatch" : nil
  }

  private static func similarity(_ lhs: String, _ rhs: String) -> Double {
    let left = tokens(lhs)
    let right = tokens(rhs)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    let shared = lcsLength(left, right)
    return Double(shared) / Double(max(left.count, right.count))
  }

  private static func tokens(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
      .map(String.init)
  }

  private static func lcsLength(_ lhs: [String], _ rhs: [String]) -> Int {
    var previous = Array(repeating: 0, count: rhs.count + 1)
    for left in lhs {
      var current = Array(repeating: 0, count: rhs.count + 1)
      for (index, right) in rhs.enumerated() {
        current[index + 1] =
          left == right
          ? previous[index] + 1 : max(previous[index + 1], current[index])
      }
      previous = current
    }
    return previous[rhs.count]
  }
}

struct CaptionBaseline: Codable, Equatable, Sendable {
  let source: TranscriptSource
  let cueStartFrame: Int
  let cueEndFrame: Int
  let sentenceTimingNeedsReview: Bool
  let wordTimingNeedsReview: Bool
  let timingReviewReason: String?
  let originalTokens: [TranscriptWordToken]?

  init(
    source: TranscriptSource, cueStartFrame: Int, cueEndFrame: Int,
    sentenceTimingNeedsReview: Bool, wordTimingNeedsReview: Bool,
    timingReviewReason: String?, originalTokens: [TranscriptWordToken]? = nil
  ) {
    self.source = source
    self.cueStartFrame = cueStartFrame
    self.cueEndFrame = cueEndFrame
    self.sentenceTimingNeedsReview = sentenceTimingNeedsReview
    self.wordTimingNeedsReview = wordTimingNeedsReview
    self.timingReviewReason = timingReviewReason
    self.originalTokens = originalTokens
  }

  func applying(
    startFrame: Int, endFrame: Int, wordTimingNeedsReview: Bool,
    resolvesTimingReview: Bool
  ) -> CaptionBaseline {
    CaptionBaseline(
      source: source, cueStartFrame: cueStartFrame, cueEndFrame: cueEndFrame,
      sentenceTimingNeedsReview: resolvesTimingReview ? false : sentenceTimingNeedsReview,
      wordTimingNeedsReview: wordTimingNeedsReview,
      timingReviewReason: resolvesTimingReview ? nil : timingReviewReason,
      originalTokens: originalTokens)
  }
}
