import Foundation

struct UKPhoneMeasurement: Codable, Equatable, Sendable {
  let source: AudioSpan
  let take: AudioSpan
  let acousticDistance: Double
  let sourceTokenSupport: Double
  let takeTokenSupport: Double
  /// A model category is not a calibrated correctness probability.
  var predictedVowel: String? = nil
  var vowelProbability: Double? = nil
  var sourceVowel: String? = nil
  var sourceVowelProbability: Double? = nil
}

struct UKReferenceEvidence: Codable, Equatable, Sendable {
  static let policy = "uk-reference-v1-experimental"
  let inventory: String
  let modelRevision: String
  let calibration: String
  let sourceDuration: Double
  let measurements: [String: [UKPhoneMeasurement]]
  var focus: [UKFocusEvidence] = []
  var stress: [UKStressEvidence]? = nil
  var issues: [String] = []
  var pitch: UKPitchEvidence? = nil
  var vad: UKVADEvidence? = nil
  var boundaries: [UKBoundaryEvidence]? = nil
  var targetParsingPolicy: String? = nil
}

struct UKFocusEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let text: String
  let source: AudioSpan
  let take: AudioSpan
  let sourceProbability: Double
  let takeProbability: Double
  let model: String
}

struct UKStressEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let text: String
  let expectedSyllable: Int?
  let sourceProbabilities: [Double]
  let takeProbabilities: [Double]
  let source: AudioSpan
  let take: AudioSpan
  let model: String
  var sourceSyllable: Int? { sourceProbabilities.indices.max(by: { sourceProbabilities[$0] < sourceProbabilities[$1] }).map { $0+1 } }
  var takeSyllable: Int? { takeProbabilities.indices.max(by: { takeProbabilities[$0] < takeProbabilities[$1] }).map { $0+1 } }
}

struct UKPitchFrame: Codable, Equatable, Sendable {
  let time: Double
  let hz: Double
  let confidence: Double
  var isVoiced: Bool { confidence > 0.9 && (46.875...2093.75).contains(hz) }
}
struct UKPitchEvidence: Codable, Equatable, Sendable {
  let policy: String
  let source: [UKPitchFrame]
  let take: [UKPitchFrame]
  /// Center independently on each speaker's median; a low voice is not an error.
  static func apply(_ pitch: [UKPitchFrame], to track: DeliveryTrack) -> DeliveryTrack {
    let voiced = pitch.filter(\.isVoiced).map(\.hz).sorted()
    let median = voiced.isEmpty ? nil : voiced[voiced.count/2]
    let frames = track.frames.map { frame -> DeliveryFrame in
      let i = Int(((frame.time*16000-127.5)/256).rounded())
      let point = pitch.indices.contains(i) ? pitch[i] : nil
      let relative = point.flatMap { p in p.isVoiced ? median.map { 12*log2(p.hz/$0) } : nil }
      return .init(time: frame.time, relativeDB: frame.relativeDB, pitchSemitones: relative)
    }
    return .init(duration: track.duration, frames: frames, pauses: track.pauses, activeSpan: track.activeSpan)
  }
}

struct UKBoundaryEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let text: String
  let source: AudioSpan
  let take: AudioSpan
  let sourceProbability: Double
  let takeProbability: Double
  let model: String
}

struct UKVADEvidence: Codable, Equatable, Sendable {
  let policy: String
  let source: [AudioSpan]
  let take: [AudioSpan]
  static func apply(_ speech: [AudioSpan], to track: DeliveryTrack) -> DeliveryTrack {
    let pauses = zip(speech, speech.dropFirst()).compactMap { left, right -> AudioSpan? in
      right.start-left.end >= 0.18 ? .init(start: left.end, end: right.start) : nil
    }
    let active = speech.first.flatMap { first in speech.last.map { AudioSpan(start: first.start, end: $0.end) } }
    return .init(duration: track.duration, frames: track.frames, pauses: pauses, activeSpan: active)
  }
}

struct UKVowelPrediction: Sendable {
  let symbol: String
  let probability: Double
}
