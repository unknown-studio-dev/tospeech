import Foundation

/// Experimental CTC evidence. No field is a calibrated pronunciation percentage.
struct PhoneticXeusPhoneEvidence: Codable, Equatable, Sendable {
  let expected: String
  let status: String
  let reason: String?
  let start: Double?
  let end: Double?
  let expectedProbability: Double?
  let logMargin: Double?
  let closestPhone: String?
  let confidence: Double?
  let sourceStart: Double?
  let sourceEnd: Double?
  let sourceStatus: String?
  var diagnostic: XeusPhoneDiagnostic? = nil
  var expectedTokenProbability: Double? = nil
  var unitID: String? = nil
  var licence: String? = nil
  var licensedRealization: String? = nil
  /// What the reference audio actually realized for this unit, licensed or not. Diagnostic only.
  var referenceRealization: String? = nil
  var referenceStatus: String? = nil
  var takeStatus: String? = nil
  var takeReason: String? = nil
  var referenceMatch: Bool? = nil
  var contrast: XeusContrast? = nil
}

/// Contrast-head decision for RP vowels the CTC labels collapse (BATH, LOT). Never a score.
struct XeusContrast: Codable, Equatable, Sendable { let name: String; let pUK: Double; let decision: String }
struct XeusContrastHead: Codable, Equatable, Sendable { let version: String; let layer: Int; let contrasts: [String]; let sha256: String }

struct PhoneticXeusEvidence: Codable, Equatable, Sendable {
  struct Word: Codable, Equatable, Sendable {
    let id: String
    let variant: [String]
    let phones: [PhoneticXeusPhoneEvidence]
  }
  let revision: String
  let policy: String
  let mapping: String
  let device: String
  let dtype: String
  let duration: Double
  let sourceDuration: Double
  let sourceShape: [Int]
  let takeShape: [Int]
  let inferenceSeconds: Double
  let loadSeconds: Double
  let peakRSS: UInt64
  let words: [Word]
  let recognizedPhones: [RecognizedPhone]
  var sourceRecognizedPhones: [RecognizedPhone]? = nil
  var reference: XeusReferenceDiagnostics? = nil
  var deliveryError: String? = nil
  var referencePolicy: String? = nil
  var contrastHead: XeusContrastHead? = nil
}

struct XeusPhoneDiagnostic: Codable, Equatable, Sendable {
  struct Hypothesis: Codable, Equatable, Sendable {
    let status: String
    let reason: String?
    let expectedProbability: Double?
    let logMargin: Double?
    let closestPhone: String?
    var expectedTokenProbability: Double? = nil
  }
  let groupID: String
  let state: String
  let sourceHypothesis: Hypothesis
  let takeHypothesis: Hypothesis
  let lengthStatus: String
  var unitID: String? = nil
  var licence: String? = nil
}

/// Source-defined groups are shared evidence, not independent per-phone scores.
struct XeusReferenceDiagnostics: Codable, Equatable, Sendable {
  static let policy = "xeus-reference-diagnostics-v1"
  static let policyV2 = "xeus-reference-diagnostics-v2"
  struct Candidate: Codable, Equatable, Sendable {
    let symbol: String
    let posterior: Double
  }
  struct Token: Codable, Equatable, Sendable {
    let symbol: String
    let startFrame: Int
    let endFrame: Int
    let posterior: Double
  }
  struct Region: Codable, Equatable, Sendable {
    let startFrame: Int
    let endFrame: Int
    let start: Double
    let end: Double
    let tokens: [Token]
    let speechFrames: Int
    let blankMean: Double
    let topCandidates: [Candidate]
    var sequence: String { tokens.map(\.symbol).joined(separator: " ") }
  }
  struct Member: Codable, Equatable, Sendable, Hashable {
    let wordID: String
    let phoneIndex: Int
    let displayPhone: String
  }
  struct Comparison: Codable, Equatable, Sendable {
    let state: String
    let jsDistance: Double?
    let pathSteps: Int
    let sequenceEditDistance: Int?
  }
  struct Group: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let members: [Member]
    let source: Region?
    let take: Region?
    let shared: Bool
    let takeBoundaryShared: Bool?
    let comparison: Comparison
    var hasMatchingSequence: Bool {
      guard let source, let take, !source.tokens.isEmpty else { return false }
      return source.tokens.map(\.symbol) == take.tokens.map(\.symbol)
    }
  }
  let policy: String
  let groups: [Group]
}
