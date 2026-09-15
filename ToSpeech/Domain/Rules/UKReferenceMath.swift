import Foundation

enum UKReferenceMath {
  struct Matrix: Sendable {
    let values: [Float]
    let frames: Int
    let width: Int
    func row(_ frame: Int) -> ArraySlice<Float> { values[(frame*width)..<((frame+1)*width)] }
  }
  static func logProbabilities(_ matrix: Matrix) throws -> [[Float]] {
    guard matrix.frames > 0, matrix.frames <= 1600, matrix.width > 0,
      matrix.values.count == matrix.frames*matrix.width, matrix.values.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
    return (0..<matrix.frames).map { index in
      let row = matrix.row(index), maximum = row.max()!
      let normalizer = maximum + log(row.reduce(Float(0)) { $0+exp($1-maximum) })
      return row.map { $0-normalizer }
    }
  }
  static func mean(_ matrix: Matrix, start: Int, end: Int) -> [Double]? {
    guard start >= 0, end > start, end <= matrix.frames else { return nil }
    var mean = Array(repeating: 0.0, count: matrix.width)
    for frame in start..<end { for (i, value) in matrix.row(frame).enumerated() { mean[i] += Double(value)/Double(end-start) } }
    return mean.allSatisfy(\.isFinite) ? mean : nil
  }
  static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double? {
    guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
    let aa = a.reduce(0) { $0+$1*$1 }, bb = b.reduce(0) { $0+$1*$1 }
    guard aa > 1e-12, bb > 1e-12 else { return nil }
    return min(2, max(0, 1-zip(a,b).reduce(0) { $0+$1.0*$1.1 }/sqrt(aa*bb)))
  }
  /// CTC emissions are narrow. Midpoints allocate intervening frames within each
  /// known word only; no expansion crosses its supplied source boundary.
  static func regions(_ spans: [CTCAlignment.Span], lower: Int, upper: Int) -> [CTCAlignment.Span] {
    guard !spans.isEmpty, lower >= 0, upper > lower,
      spans.allSatisfy({ $0.start >= lower && $0.end <= upper && $0.end > $0.start }),
      zip(spans, spans.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { return [] }
    return spans.indices.map { i in
      .init(start: i == 0 ? lower : (spans[i-1].end+spans[i].start)/2,
        end: i+1 == spans.count ? upper : (spans[i].end+spans[i+1].start)/2)
    }
  }
  static func support(_ rows: [[Float]], labels: [Int], spans: [CTCAlignment.Span]) -> Double {
    guard labels.count == spans.count, !labels.isEmpty else { return 0 }
    var total = 0.0
    for (id, span) in zip(labels, spans) {
      guard span.start >= 0, span.end > span.start, span.end <= rows.count else { return 0 }
      total += Double((span.start..<span.end).map { rows[$0][id] }.max() ?? -100)
    }
    return exp(total/Double(labels.count))
  }
}
