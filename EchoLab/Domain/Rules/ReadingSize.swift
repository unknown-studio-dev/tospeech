import Foundation

enum ReadingSize {
  static let range = 80...160
  static let step = 10
  static let defaultPercent = 100

  static func normalized(_ value: Int) -> Int {
    let clamped = min(range.upperBound, max(range.lowerBound, value))
    return Int((Double(clamped) / Double(step)).rounded()) * step
  }
}
