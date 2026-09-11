import SwiftUI

enum EchoMetrics {
  static let controlRadius: CGFloat = 8
  static let panelRadius: CGFloat = 14
  static let contentPadding: CGFloat = 24
  static let controlGap: CGFloat = 8
  static let sectionGap: CGFloat = 24
  static let focusWidth: CGFloat = 2
  static let sidebarWidth: CGFloat = 200
  static let windowSize = CGSize(width: 1280, height: 860)
  static let spacing: [CGFloat] = [4, 8, 12, 16, 24, 32]
  static let popoverRadius: CGFloat = 12
  static let popoverPadding: CGFloat = 20
  static let compactIcon: CGFloat = 14
  static let controlIcon: CGFloat = 16
  static let wordPadding: CGFloat = 12
  static let menuPadding: CGFloat = 6
  static let menuGap: CGFloat = 4
  static let menuRowHeight: CGFloat = 32
}

enum EchoControlSize: String, CaseIterable, Identifiable {
  case compact, regular, practice, prominent
  var id: String { rawValue }
  var height: CGFloat {
    switch self {
    case .compact: 32
    case .regular: 36
    case .practice: 40
    case .prominent: 44
    }
  }
}
