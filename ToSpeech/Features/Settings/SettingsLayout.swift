import SwiftUI

enum SettingsLayoutMetrics {
  static let pageInset: CGFloat = 32
  static let gap: CGFloat = 24
  static let twoColumnMinimum: CGFloat = 1016

  enum Composition { case general, recording }

  static func firstColumn(width: CGFloat, composition: Composition) -> CGFloat {
    guard width >= twoColumnMinimum else { return width }
    switch composition {
    case .general: return width - gap - ceil((width - gap) * 0.38 / 4) * 4
    case .recording: return min(480, max(340, 400 + (width - 1176) * 2 / 9))
    }
  }
}

/// Short windows scroll; narrow windows stack without shrinking controls.
struct SettingsColumns: Layout {
  var composition: SettingsLayoutMetrics.Composition

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 736
    let sizes = measured(width: width, subviews: subviews)
    let height = width < SettingsLayoutMetrics.twoColumnMinimum
      ? sizes.map(\.height).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * SettingsLayoutMetrics.gap
      : sizes.map(\.height).max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = measured(width: bounds.width, subviews: subviews)
    var point = bounds.origin
    for (view, size) in zip(subviews, sizes) {
      view.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
      if bounds.width < SettingsLayoutMetrics.twoColumnMinimum {
        point.y += size.height + SettingsLayoutMetrics.gap
      } else {
        point.x += size.width + SettingsLayoutMetrics.gap
      }
    }
  }

  private func measured(width: CGFloat, subviews: Subviews) -> [CGSize] {
    let first = SettingsLayoutMetrics.firstColumn(width: width, composition: composition)
    return subviews.enumerated().map { index, view in
      let columnWidth = width < SettingsLayoutMetrics.twoColumnMinimum ? width
        : index == 0 ? first : width - first - SettingsLayoutMetrics.gap
      let size = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
      return CGSize(width: columnWidth, height: size.height)
    }
  }
}

struct SettingsSection<Content: View>: View {
  let title: String
  let subtitle: String
  var spacing: CGFloat = 16
  var titleSize: CGFloat = 20
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      VStack(alignment: .leading, spacing: 6) {
        EchoLocalizedText(title).font(EchoFont.heading(size: titleSize, weight: .semibold))
        EchoLocalizedText(subtitle).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      }
      content
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(24).background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SettingsPreferenceRow<Control: View>: View {
  let title: String
  @ViewBuilder var control: Control

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 20) {
        EchoLocalizedText(title).fixedSize()
        Spacer(minLength: 0)
        control
      }
      VStack(alignment: .leading, spacing: 8) {
        EchoLocalizedText(title)
        control
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.font(EchoFont.body(size: 16)).padding(.vertical, 8)
  }
}
