import Foundation

struct ContentMatchingJob: Codable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable { case queued, running, complete, failed, unrecognized }
  let id: UUID
  let takeID: UUID
  let target: ProductionPracticeTargetSnapshot
  let selection: TranscriptionSelection
  let locale: String
  let provenance: TranscriptionProvenance
  let audioChecksum: String
  let createdAt: Date
  let policy: String
  var status: Status
  var transcription: AudioTranscription?
  var match: ContentMatch?
  var error: String?
  var errorLocalizationKey: String? = nil

  var isPending: Bool { status == .queued || status == .running }
}
