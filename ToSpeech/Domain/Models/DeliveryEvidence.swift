import Foundation

struct DeliveryFrame: Codable, Equatable, Sendable {
  let time: Double
  let relativeDB: Double
  let pitchSemitones: Double?
}

struct DeliveryTrack: Codable, Equatable, Sendable {
  let duration: Double
  let frames: [DeliveryFrame]
  let pauses: [AudioSpan]
  let activeSpan: AudioSpan?
  var pitchFrames: Int { frames.filter { $0.pitchSemitones != nil }.count }
  var activeDuration: Double? { activeSpan?.duration }
  var endingPitchChange: Double? {
    guard let end = frames.last(where: { $0.pitchSemitones != nil })?.time else { return nil }
    let ending = frames.filter { $0.time >= end-0.5 }.compactMap(\.pitchSemitones)
    guard ending.count >= 8 else { return nil }
    return ending.suffix(3).reduce(0,+)/3 - ending.prefix(3).reduce(0,+)/3
  }
}

struct DeliveryWordEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let text: String
  let source: AudioSpan
  let take: AudioSpan
  let sourceDB: Double
  let takeDB: Double
}

struct DeliveryBoundary: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let phrase: String
  let source: AudioSpan
  let take: AudioSpan
  let sourcePause: Double
  let takePause: Double
}

struct DeliveryEvidence: Codable, Equatable, Sendable {
  static let currentPolicy = "acoustic-comparison-v1"
  var policy = Self.currentPolicy
  var pitchModel: String? = nil
  let source: DeliveryTrack?
  let take: DeliveryTrack?
  var words: [DeliveryWordEvidence] = []
  var boundaries: [DeliveryBoundary] = []
  var error: String? = nil
}
