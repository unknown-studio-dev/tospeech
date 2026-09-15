import Foundation

/// A space emitted at the end of the previous sentence can precede the next
/// spoken word by seconds. It is not that word's acoustic onset. Keep the ASR
/// onset context when separated from the first character emission; otherwise the
/// drift gate rejects a well-supported word end and restores a truncated ASR clip.
enum CTCSentenceOnset {
  static func start(observedStart: Double, firstEmission: Double,
    precedingBoundary: Double?, chunkStart: Double
  ) -> Double {
    if let precedingBoundary, firstEmission - precedingBoundary <= 0.12 {
      // Continuous speech still uses the shared boundary; do not cut into it.
      return max(chunkStart, precedingBoundary)
    }
    // Retain earlier observed onset context, but never cross the preceding word
    // boundary or the decoded chunk. The 40 ms margin matches the existing edge
    // policy; it is not a claim that the character peak marks phoneme onset.
    return max(chunkStart, precedingBoundary ?? chunkStart,
      min(observedStart, firstEmission - 0.04))
  }
}
