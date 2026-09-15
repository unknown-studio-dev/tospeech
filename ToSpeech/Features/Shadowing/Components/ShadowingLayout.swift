import Foundation

/// D02's 1032 pt content area: 576 pt video + 24 pt gap + 432 pt transcript.
struct ShadowingLayout {
  let contentWidth: CGFloat
  var contentHeight: CGFloat = 752
  static let columnGap: CGFloat = 24
  static let sectionGap: CGFloat = 20
  static let transportHeight: CGFloat = 108
  var readingScale: CGFloat {
    min(44 / 34, max(0.9, min(contentWidth / 1032, contentHeight / 752 * 1.2)))
  }
  var controlScale: CGFloat { min(1.2, max(1, readingScale)) }
  var scaledTransportHeight: CGFloat { Self.transportHeight * controlScale }
  // Reserve space for the reading panel before allowing video to grow on wide displays.
  var videoWidth: CGFloat {
    let proportional = max(0, contentWidth - Self.columnGap) * 4 / 7
    let heightBudget = max(220, 324 + (contentHeight - 752) * 0.42)
    return min(proportional, heightBudget * 16 / 9)
  }
  var transcriptWidth: CGFloat { max(0, contentWidth - Self.columnGap - videoWidth) }
  var videoHeight: CGFloat { videoWidth * 9 / 16 }
  var mediaRowHeight: CGFloat { videoHeight + 40 }
  var reviewSourceWidth: CGFloat { min(640, max(300, contentWidth * 416 / 1032)) }
  var reviewDrawerWidth: CGFloat { min(432, max(0, contentWidth)) }
}
