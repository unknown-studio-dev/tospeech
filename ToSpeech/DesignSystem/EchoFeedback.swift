import SwiftUI

struct EchoActivityIndicator: View {
  var body: some View {
    SwiftUI.ProgressView().controlSize(.small).tint(EchoTheme.accent)
  }
}

enum EchoStatusTone: String, CaseIterable, Identifiable {
  case neutral, info, success, warning, error
  var id: String { rawValue }
  var color: Color {
    switch self {
    case .neutral: EchoTheme.secondaryText
    case .info: EchoTheme.accent
    case .success: EchoTheme.success
    case .warning: EchoTheme.caution
    case .error: EchoTheme.danger
    }
  }
  var background: Color {
    switch self {
    case .neutral: EchoTheme.raised
    case .info: EchoTheme.selection
    case .success: EchoTheme.successSurface
    case .warning: EchoTheme.warning
    case .error: EchoTheme.errorSurface
    }
  }
  var symbol: String {
    switch self {
    case .neutral: "circle.dashed"
    case .info: "info.circle"
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "exclamationmark.circle"
    }
  }
}

struct EchoStatusBadge: View {
  var title: String
  var tone: EchoStatusTone = .neutral
  var symbol: String? = nil
  var body: some View {
    Label {
      EchoLocalizedText(title)
    } icon: {
      Image(systemName: symbol ?? tone.symbol)
    }.font(EchoFont.metadata)
      .padding(.horizontal, 8).padding(.vertical, 5)
      .foregroundStyle(tone.color)
      .background(tone.background, in: RoundedRectangle(cornerRadius: 6))
      .accessibilityElement(children: .combine)
  }
}

struct EchoInlineFeedback: View {
  var title: String
  var message: String
  var tone: EchoStatusTone = .info
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        EchoLocalizedText(title).font(EchoFont.body(size: 14, weight: .semibold)).foregroundStyle(tone.color)
        EchoLocalizedText(message).font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let actionTitle, let action {
        EchoButton(actionTitle, size: .compact, action: action)
      }
    }.padding(16).background(
      EchoTheme.surface, in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius)
    )
    .overlay(RoundedRectangle(cornerRadius: EchoMetrics.controlRadius).strokeBorder(tone.color))
  }
}

struct EchoSpinner: View {
  var size: ControlSize = .small
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  var body: some View {
    Group {
      if systemReduceMotion || previewReduceMotion {
        Image(systemName: "hourglass")
      } else {
        SwiftUI.ProgressView().controlSize(size)
      }
    }.foregroundStyle(EchoTheme.secondaryText)
  }
}

struct EchoLoading: View {
  var title: String
  var fraction: Double? = nil
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.echoReduceMotion) private var previewReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if fraction == nil {
          EchoSpinner()
        }
        EchoLocalizedText(title).font(EchoFont.body(size: 13))
        Spacer()
        if let fraction {
          Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            .font(EchoFont.mono(size: 12))
        }
      }
      if let fraction {
        SwiftUI.ProgressView(value: min(1, max(0, fraction))).tint(EchoTheme.accent)
          .echoAccessibilityLabel(title)
      }
    }.foregroundStyle(EchoTheme.secondaryText).accessibilityElement(children: .combine)
  }
}

struct EchoSkeleton: View {
  var height: CGFloat = 16
  var radius: CGFloat = 4
  var body: some View {
    RoundedRectangle(cornerRadius: radius).fill(EchoTheme.hover).frame(height: height)
      .accessibilityHidden(true)
  }
}

struct EchoValueSlider: View {
  var title: String
  @Binding var value: Double
  var range: ClosedRange<Double>
  var step: Double = 0.25
  var unit = "×"
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        EchoLocalizedText(title)
        Spacer()
        Text("\(EchoFormat.decimal(value))\(unit)").font(EchoFont.mono(size: 13))
      }.font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.text)
      EchoSlider(
        value: $value, range: range, step: step, label: title,
        valueLabel: "\(EchoFormat.decimal(value))\(unit)")
    }
  }
}
