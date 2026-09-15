import Foundation

/// Source audio is levelled once, when the stored copy is written. Raw YouTube
/// speech sits near −21 LUFS while YouTube plays it around −14 LUFS (its Stable
/// Volume compressor lifts quiet speech), so lessons sounded quieter in the app
/// than online. The gain is a single linear step so word-stress contrasts and
/// pauses survive untouched; only peaks that would exceed the ceiling are
/// limited, which is what makes the boost fit at all (peaks already sit at
/// 0 dBFS in typical downloads).
enum SourceLoudness {
  static let targetLUFS = -16.0
  static let ceilingDBFS = -1.0
  static let maximumBoostDB = 12.0
  /// Differences this small are inaudible; leave the encode untouched.
  static let deadbandDB = 0.5
  /// ffmpeg reports around −70 LUFS for silence or clips too short to gate;
  /// there is nothing to level below this.
  static let measurableFloorLUFS = -60.0

  /// `ffmpeg -af <measurementFilter> -f null -` prints an EBU R128 summary on
  /// stderr; `integratedLoudness(in:)` reads it back.
  static let measurementFilter = "ebur128"

  static func integratedLoudness(in report: String) -> Double? {
    guard let summary = report.range(of: "Integrated loudness:") else { return nil }
    for line in report[summary.upperBound...].split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("I:") else { continue }
      let value = trimmed.dropFirst(2).replacingOccurrences(of: "LUFS", with: "")
        .trimmingCharacters(in: .whitespaces)
      return Double(value)
    }
    return nil
  }

  /// The linear gain that brings `measuredLUFS` to the target: never more than
  /// `maximumBoostDB` up, unlimited down, zero inside the dead band or when the
  /// measurement is silence.
  static func gainDB(measuredLUFS: Double) -> Double {
    guard measuredLUFS.isFinite, measuredLUFS > measurableFloorLUFS else { return 0 }
    let gain = targetLUFS - measuredLUFS
    guard abs(gain) >= deadbandDB else { return 0 }
    return min(maximumBoostDB, gain)
  }

  /// The ffmpeg filter chain for the stored encode, or `nil` when the audio is
  /// already at level. `minimumFrames` pads the end so a re-encoded file is
  /// never shorter than the one whose timing the lesson already carries.
  static func filter(gainDB: Double, minimumFrames: Int? = nil) -> String? {
    var stages: [String] = []
    if gainDB != 0 {
      let limit = pow(10, ceilingDBFS / 20)
      stages.append(String(format: "volume=%.2fdB", gainDB))
      stages.append(String(format: "alimiter=limit=%.4f:attack=5:release=50:level=false", limit))
    }
    if let minimumFrames, minimumFrames > 0 { stages.append("apad=whole_len=\(minimumFrames)") }
    return stages.isEmpty ? nil : stages.joined(separator: ",")
  }

  /// Arguments for the stored AAC encode of `source` into `destination`.
  static func encodeArguments(source: URL, destination: URL, gainDB: Double, minimumFrames: Int? = nil) -> [String] {
    var arguments = ["-y", "-i", source.path, "-vn"]
    if let filter = filter(gainDB: gainDB, minimumFrames: minimumFrames) { arguments += ["-af", filter] }
    return arguments + ["-c:a", "aac", "-b:a", "192k", destination.path]
  }

  static func measurementArguments(source: URL) -> [String] {
    ["-hide_banner", "-nostats", "-i", source.path, "-vn", "-af", measurementFilter, "-f", "null", "-"]
  }
}

/// One stored source file's levelling outcome.
struct SourceLevelReport: Equatable, Sendable {
  var relativePath: String
  var measuredLUFS: Double?
  var gainDB: Double
  var applied: Bool
}
