import Foundation

struct PronunciationJob: Codable, Equatable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable { case queued, running, complete, failed, unrecognized }
  let id: UUID
  let takeID: UUID
  let target: ProductionPracticeTargetSnapshot
  let words: [PronunciationWordTarget]
  let accent: ReferenceAccent
  let provenance: String
  let sourceAudioChecksum: String?
  let audioChecksum: String
  let createdAt: Date
  var status: Status
  var result: PronunciationEvidence?
  var error: String?
  var errorWord: String? = nil
  var inlineMessageKey: String {
    if status == .complete { return "assessment.inline_ready" }
    if status == .failed || status == .unrecognized, let error, !error.isEmpty { return error }
    return "assessment.status.\(status.rawValue)"
  }
  var engineTitle: String {
    if provenance.hasPrefix("PhoneticXeus") { return "PhoneticXeus · UK" }
    if provenance.hasPrefix("UK Reference") { return "UK Reference" }
    if provenance.hasPrefix("Phone Scorer") { return "Phone E16 · US" }
    return "Buddy"
  }
  var isPending: Bool { status == .queued || status == .running }
}
