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
    let matches = tokens.filter { token in
      IPAFormatting.isPronounceable(token.text) && range(for: token, in: target)?.contains(frame) == true
    }
    // Don't choose an arbitrary word when stored intervals overlap.
    return matches.count == 1 ? matches.first?.id : nil
  }
}
