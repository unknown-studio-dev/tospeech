import SwiftUI

struct EchoLinkMarker: View {
  var label: String
  var scale: CGFloat = 1
  var selected = false
  var action: () -> Void
  @FocusState private var focused: Bool
  @State private var hovered = false

  var body: some View {
    GeometryReader { geometry in
      if geometry.size.width > 0 && geometry.size.height > 0 {
        Button(action: action) {
          LinkingBridge()
            .stroke(EchoTheme.accent, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
            .frame(width: 22 * scale, height: 10 * scale)
            .padding(.bottom, 4 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(hovered || selected ? EchoTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused).echoFocusRing(focused)
        .onHover { hovered = $0 }.accessibilityLabel(label).help(label)
      }
    }.frame(idealWidth: 28 * scale, idealHeight: 48 * scale)
  }
}

/// An inline pronunciation mark with explicit stroke clearance, independent of
/// a font's below-baseline glyph bounds. The surrounding button owns the hit area.
private struct LinkingBridge: Shape {
  func path(in rect: CGRect) -> Path {
    let inset = rect.height * 0.15
    var path = Path()
    path.move(to: CGPoint(x: inset, y: inset))
    path.addCurve(to: CGPoint(x: rect.maxX - inset, y: inset),
      control1: CGPoint(x: inset, y: rect.maxY - inset),
      control2: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
    return path
  }
}

struct LinkingMarkerLayoutKey: LayoutValueKey { static let defaultValue = false }

/// A bridge is hidden when its adjacent words land on different lines. Lookahead
/// moves a pair together when it fits; long chains can still wrap without overflow.
struct LinkingWordFlowLayout: Layout {
  var lineSpacing: CGFloat = 12

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 900, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for i in subviews.indices {
      let point = result.points[i]
      subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        proposal: result.hidden.contains(i) ? .zero : .unspecified)
    }
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint], hidden: Set<Int>) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    var points = Array(repeating: CGPoint.zero, count: subviews.count)
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
    for i in subviews.indices {
      let marker = subviews[i][LinkingMarkerLayoutKey.self]
      var needed = sizes[i].width
      if !marker, i + 2 < subviews.count, subviews[i + 1][LinkingMarkerLayoutKey.self] {
        let pair = needed + sizes[i + 1].width + sizes[i + 2].width
        if pair <= width { needed = pair }
      }
      if !marker, x > 0, x + needed > width { x = 0; y += row + lineSpacing; row = 0 }
      points[i] = CGPoint(x: x, y: y)
      x += sizes[i].width
      row = max(row, sizes[i].height)
    }
    let hidden = Set(subviews.indices.filter { i in
      subviews[i][LinkingMarkerLayoutKey.self] && (i == 0 || i + 1 == subviews.count
        || points[i - 1].y != points[i + 1].y)
    })
    return (CGSize(width: width, height: y + row), points, hidden)
  }
}
