import Foundation

/// Availability and review are independent: an ASR disagreement does not erase
/// its observed interval. These ranges support listening, not verified alignment
/// or assessment. Missing/invalid intervals still use sentence context.
enum ProductionWordTiming {
  static func range(for token: TranscriptWordToken, in target: ProductionPracticeTarget) -> Range<Int>? {
    guard target.startFrame >= 0, target.endFrame > target.startFrame,
      let start = token.startFrame, let end = token.endFrame,
      start >= target.startFrame, end > start, end <= target.endFrame
    else { return nil }
    return start..<end
  }

  static func previewRange(for token: TranscriptWordToken, in target: ProductionPracticeTarget) -> Range<Int> {
    range(for: token, in: target) ?? target.startFrame..<target.playbackEndFrame
  }

  static func playingWordID(at frame: Int, tokens: [TranscriptWordToken], in target: ProductionPracticeTarget) -> String? {
    guard frame >= target.startFrame, frame <= target.playbackEndFrame else { return nil }
    let started = tokens.compactMap { token -> (TranscriptWordToken, Int)? in
      guard IPAFormatting.isPronounceable(token.text),
        let interval = range(for: token, in: target), interval.lowerBound <= frame
      else { return nil }
      return (token, interval.lowerBound)
    }
    guard let latestStart = started.map({ $0.1 }).max() else { return nil }
    let matches = started.filter { $0.1 == latestStart }
    // A word stays active through its following pause. Only a uniquely timed
    // next word clears it; identical starts remain ambiguous rather than guessed.
    return matches.count == 1 ? matches[0].0.id : nil
  }
}
