import SwiftUI

enum EchoFont {
  static func body(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
    -> Font
  {
    .system(size: size, weight: weight, design: design)
  }
  static func heading(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
  static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  static let sentence = body(size: 30, weight: .medium)
  static let ipa = body(size: 16)
  static let translation = body(size: 17)
  static let control = body(size: 14, weight: .medium)
  static let metadata = body(size: 12)
}
