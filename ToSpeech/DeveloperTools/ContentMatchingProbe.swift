#if DEBUG
import AVFAudio
import CryptoKit
import Foundation

/// Developer integration probe: a supplied audio fixture is committed as a take
/// in an isolated database. This does not exercise microphone capture or claim
/// learner pronunciation accuracy. It never downloads a package.
@MainActor enum ContentMatchingProbe {
  static func run(audioURL: URL, outputDirectory: URL) async throws {
    let paths = BackendPaths(root: outputDirectory.appendingPathComponent("matching-probe-\(UUID())"))
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let liveDatabase = try ProductionDatabase(url: BackendPaths.live.database)
    let adapter = ParakeetTranscriptionAdapter(database: liveDatabase, paths: .live)
    try await adapter.validate(modelID: TranscriptionSelection.parakeet.modelID)
    let file = try AVAudioFile(forReading: audioURL)
    let sampleRate = Int(file.processingFormat.sampleRate), frameCount = Int(file.length)
    let source = paths.sourceAudio.appendingPathComponent("fixture.caf")
    try FileManager.default.copyItem(at: audioURL, to: source)
    let checksum = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
    let lesson = try await database.insertLesson(NewLesson(provider: "matching-probe",
      externalID: UUID().uuidString, title: "Synthetic speech fixture — not microphone capture"))
    let jobID = UUID(), runToken = UUID()
    try await database.persistImportJob(id: jobID, lessonID: lesson.id,
      expectedGeneration: lesson.generation, runToken: runToken, inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(cues: [CaptionCue(start: 0,
      end: Double(frameCount) / Double(sampleRate), text: "I never thought it would make such a difference.")],
      source: .creatorCaption, sampleRate: sampleRate, frameCount: frameCount)
    let asset = MediaAsset(id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/fixture.caf", checksum: checksum, format: "caf",
      sampleRate: sampleRate, frameCount: frameCount, createdAt: Date())
    try await database.publishPreparedLesson(lessonID: lesson.id, expectedGeneration: lesson.generation,
      jobID: jobID, runToken: runToken, title: lesson.title, author: nil, assets: [asset], segments: segments, checkpointJSON: "{}")
    guard let target = try await database.practiceTarget(lessonID: lesson.id, paths: paths) else {
      throw ProductionPracticeError.invalidTarget
    }
    let ids = try await database.beginPracticeCapture(target: target, sessionID: nil, sourceSpeed: 1,
      targetJSON: String(decoding: JSONEncoder().encode(target.snapshot), as: UTF8.self))
    let handle = ProductionCaptureHandle(sessionID: ids.sessionID, roundID: ids.roundID,
      takeID: ids.takeID, target: target, sourceSpeed: 1,
      stagingURL: paths.takeStaging.appendingPathComponent("\(ids.takeID).caf"),
      finalURL: paths.finalTakes.appendingPathComponent("\(ids.takeID).caf"),
      manifestURL: paths.takeStaging.appendingPathComponent("\(ids.takeID).json"))
    try FileManager.default.copyItem(at: source, to: handle.finalURL)
    try await database.commitPracticeTake(handle: handle, assetID: UUID(),
      relativePath: "Takes/Final/\(ids.takeID).caf", checksum: checksum,
      sampleRate: sampleRate, frameCount: frameCount, outcome: .complete)
    guard let take = try await database.practiceTakes(lessonID: lesson.id).first else {
      throw ProductionPracticeError.sourceUnavailable
    }
    let service = ContentMatchingService(database: database, paths: paths,
      adapters: TranscriptionAdapterRegistry([adapter]))
    let started = Date()
    await service.enqueue(take, preferences: Preferences())
    for _ in 0..<480 {
      if let result = service.jobs.last, !result.isPending {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputDirectory.appendingPathComponent("matching-probe-result.json"))
        print("MATCHING_PROBE: status=\(result.status.rawValue), words=\(result.match?.words.count ?? 0), differences=\(result.match?.differences.count ?? 0), elapsed=\(Date().timeIntervalSince(started)), database=\(paths.database.path)")
        guard result.status == .complete else {
          throw ProductionPracticeError.recoveryRequired(result.error ?? result.status.rawValue)
        }
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ProductionPracticeError.recoveryRequired(service.error ?? "Matching probe timed out")
  }
}
#endif
