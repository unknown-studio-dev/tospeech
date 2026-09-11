import SwiftUI

enum EchoTheme {
  // Pencil D00: approved navy/lavender foundation. Values live only in this file.
  static let canvas = Color(hex: 0x151C2B)
  static let surface = Color(hex: 0x1D2738)
  static let raised = Color(hex: 0x263247)
  static let text = Color(hex: 0xF0F2F6)
  static let secondaryText = Color(hex: 0xB6C1D2)
  static let accent = Color(hex: 0xC2B6E8)
  static let accentHover = Color(hex: 0xD0C6EF)
  static let accentPressed = Color(hex: 0xAA9BD2)
  static let onAccent = Color(hex: 0x151C2B)
  static let selection = Color(hex: 0x353149)
  static let hover = Color(hex: 0x33425A)
  static let border = Color(hex: 0x687C98)
  static let separator = Color(hex: 0x33425A)
  static let disabledText = Color(hex: 0x91A1B8)
  static let focus = Color(hex: 0xA7C8FF)
  static let success = Color(hex: 0xC4D995)
  static let caution = Color(hex: 0xE8C181)
  static let danger = Color(hex: 0xF0A5AA)
  static let successSurface = Color(hex: 0x2D392E)
  static let warning = Color(hex: 0x3C3327)
  static let errorSurface = Color(hex: 0x402D38)
  static let scrim = Color(hex: 0x090F1B).opacity(0.67)
  static let mediaScrim = Color.black.opacity(0.78)

  // Compatibility names used by the existing feature views during screen migration.
  static let ink = text
  static let muted = secondaryText
  static let line = separator
  static let lime = accent
  static let dark = canvas
  static let soft = raised
  static let selected = selection
  static let radius = EchoMetrics.panelRadius
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
  }
}

enum EchoFormat {
  static func time(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
  static func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }
}
