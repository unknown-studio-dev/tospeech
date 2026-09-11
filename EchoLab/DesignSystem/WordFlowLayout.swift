import SwiftUI

struct WordFlowLayout: Layout {
  var spacing: CGFloat = 7
  var lineSpacing: CGFloat = 12
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 900, subviews: subviews).size
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (index, point) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var positions: [CGPoint] = []
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += row + lineSpacing
        row = 0
      }
      positions.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      row = max(row, size.height)
    }
    return (CGSize(width: width, height: y + row), positions)
  }
}
