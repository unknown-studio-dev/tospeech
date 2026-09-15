#if DEBUG
import AVFAudio
import CryptoKit
import Foundation

/// Developer integration probe: a supplied audio fixture is committed as a take
/// in an isolated database. This does not exercise microphone capture or claim
/// learner pronunciation accuracy. It never downloads a package.
@MainActor enum PronunciationProbe {
  /// Replays Retry through the production service against an explicitly supplied
  /// copy of the user's database/audio. Never writes to the live database.
  static func retrySavedUKJob(root: URL, outputDirectory: URL) async throws {
    guard root.standardizedFileURL != BackendPaths.live.root.standardizedFileURL else {
      throw ProductionPracticeError.invalidTarget
    }
    let paths = BackendPaths(root: root)
    let database = try ProductionDatabase(url: paths.database)
    let before = try await database.pronunciationJobs()
    guard !before.contains(where: \.isPending), let failed = before.last(where: {
      $0.status == .failed && $0.provenance == UKReferencePackage.provenance
    }) else { throw ProductionPracticeError.invalidTarget }
    let package = UKReferencePackage(paths: paths)
    let service = PronunciationAssessmentService(database: database, paths: paths, dictionary: nil,
      adapter: BuddyPronunciationAdapter(package: BuddyModelPackage(paths: paths)),
      ukScorer: UKReferenceAdapter(package: package))
    let started = Date()
    await service.retry(failed)
    for _ in 0..<960 {
      if let error = service.error { throw ProductionPracticeError.playback(error) }
      if let result = service.jobs.last(where: { $0.takeID == failed.takeID }), result.id != failed.id, !result.isPending {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputDirectory.appendingPathComponent("saved-uk-retry-result.json"))
        let retained = try await database.pronunciationJobs()
        guard before.allSatisfy({ old in retained.contains(old) }) else { throw ProductionPracticeError.invalidTarget }
        print("SAVED_UK_RETRY status=\(result.status.rawValue) words=\(result.result?.words.count ?? 0) error=\(result.error ?? "none") word=\(result.errorWord ?? "none") historyPreserved=true elapsed=\(Date().timeIntervalSince(started))")
        guard result.status == .complete else { throw ProductionPracticeError.playback(result.error ?? "retry failed") }
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ProductionPracticeError.playback("Saved UK retry timed out")
  }

  static func run(audioURL: URL, outputDirectory: URL) async throws {
    let paths = BackendPaths(root: outputDirectory.appendingPathComponent("pronunciation-probe-\(UUID())"))
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let file = try AVAudioFile(forReading: audioURL)
    let sampleRate = Int(file.processingFormat.sampleRate), frameCount = Int(file.length)
    let referenceURL = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pronunciation-reference=") }).map { URL(fileURLWithPath: String($0.dropFirst("--pronunciation-reference=".count))) } ?? audioURL
    let referenceFile = try AVAudioFile(forReading: referenceURL)
    let referenceRate = Int(referenceFile.processingFormat.sampleRate), referenceFrames = Int(referenceFile.length)
    let source = paths.sourceAudio.appendingPathComponent("fixture.caf")
    try FileManager.default.copyItem(at: referenceURL, to: source)
    let checksum = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
    let lesson = try await database.insertLesson(NewLesson(provider: "pronunciation-probe",
      externalID: UUID().uuidString, title: "Synthetic speech fixture — not microphone capture"))
    let jobID = UUID(), runToken = UUID()
    try await database.persistImportJob(id: jobID, lessonID: lesson.id,
      expectedGeneration: lesson.generation, runToken: runToken, inputJSON: "{}", checkpointJSON: "{}")
    let expected = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pronunciation-text=") }).map { String($0.dropFirst("--pronunciation-text=".count)) } ?? "I never thought it would make such a difference."
    let segments = try CaptionTranscriptBuilder.build(cues: [CaptionCue(start: 0,
      end: Double(referenceFrames) / Double(referenceRate), text: expected)],
      source: .creatorCaption, sampleRate: referenceRate, frameCount: referenceFrames)
    let asset = MediaAsset(id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/fixture.caf", checksum: checksum, format: "caf",
      sampleRate: referenceRate, frameCount: referenceFrames, createdAt: Date())
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
    try FileManager.default.copyItem(at: audioURL, to: handle.finalURL)
    try await database.commitPracticeTake(handle: handle, assetID: UUID(),
      relativePath: "Takes/Final/\(ids.takeID).caf", checksum: try BuddyModelPackage.checksum(audioURL),
      sampleRate: sampleRate, frameCount: frameCount, outcome: .complete)
    guard let take = try await database.practiceTakes(lessonID: lesson.id).first else {
      throw ProductionPracticeError.sourceUnavailable
    }
    let package = BuddyModelPackage(paths: .live)
    let usesPhone = ProcessInfo.processInfo.arguments.contains("--phone-scorer-probe")
    let usesXeus = ProcessInfo.processInfo.arguments.contains("--phoneticxeus-probe")
    let usesUK = ProcessInfo.processInfo.arguments.contains("--uk-reference-probe") || usesXeus
    let ukPackage = UKReferencePackage(paths: usesXeus ? .live : paths)
    defer { if usesUK { try? FileManager.default.removeItem(at: paths.packages) } }
    if usesUK && !usesXeus { try await ukPackage.install() }
    let xeusPackage = PhoneticXeusPackage(paths: .live)
    let phonePackage = PhoneScorerPackage(paths: paths)
    if usesPhone { try await phonePackage.install() }
    // `--assessment-policy=coldSequential` forces the small-machine policy on this machine so the
    // no-warm path can be measured; without it the probe uses the machine's own policy.
    let policy: AssessmentResourcePolicy = ProcessInfo.processInfo.arguments.contains("--assessment-policy=coldSequential")
      ? .coldSequential : .current()
    // One UK adapter for both engines: XEUS scores delivery through it, and two warm encoder
    // sessions would hold ~1.5 GB each.
    let ukAdapter = UKReferenceAdapter(package: ukPackage, idleTimeout: policy.idleTimeout)
    let service = PronunciationAssessmentService(database: database, paths: paths,
      dictionary: try OfflineIPADictionary.bundled(), adapter: BuddyPronunciationAdapter(package: package), scorer: PhoneScorerAdapter(package: phonePackage),
      ukScorer: ukAdapter, ukG2P: UKG2P(package: ukPackage),
      xeusScorer: PhoneticXeusAdapter(package: xeusPackage, ukPackage: ukPackage, ukAdapter: ukAdapter, policy: policy))
    var preferences = Preferences()
    preferences.productionAssessmentEngine = usesXeus ? .phoneticXeus : usesUK ? .ukReference : usesPhone ? .phone : .buddy
    if usesUK { preferences.accent = .uk }
    if usesPhone { preferences.accent = .us }
    // `--pronunciation-repeat=N` scores the same take N times in one app process: run 1 pays the
    // cold cost (helper load, encoder build), later runs measure the warm path.
    let repeats = max(1, ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pronunciation-repeat=") })
      .flatMap { Int($0.dropFirst("--pronunciation-repeat=".count)) } ?? 1)
    // The take's own basename keeps two inputs' result JSONs apart in one output directory.
    let label = audioURL.deletingPathExtension().lastPathComponent
    for run in 1...repeats {
      let started = Date()
      // Identify this run's job by id, not by position: `jobs.last` relies on a `created_at, id`
      // tie-break, and two jobs of one take can share a second.
      let before = Set(service.jobs.map(\.id))
      await service.enqueue(take, preferences: preferences, force: run > 1)
      if let error = service.error { throw ProductionPracticeError.recoveryRequired(error) }
      var finished: PronunciationJob?
      for _ in 0..<1440 {
        if let result = service.jobs.first(where: { !before.contains($0.id) && !$0.isPending }) { finished = result; break }
        try await Task.sleep(for: .milliseconds(250))
      }
      guard let result = finished else {
        throw ProductionPracticeError.recoveryRequired(service.error ?? "Matching probe timed out")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(result)
      try data.write(to: outputDirectory.appendingPathComponent("pronunciation-probe-result.json"))
      try data.write(to: outputDirectory.appendingPathComponent("pronunciation-probe-result-\(label)-run\(run).json"))
      print("PRONUNCIATION_PROBE: status=\(result.status.rawValue), words=\(result.result?.words.count ?? 0), differences=\(result.result?.changedWords ?? 0), elapsed=\(Date().timeIntervalSince(started)), database=\(paths.database.path) input=\(label) run=\(run)")
      guard result.status == .complete else {
        throw ProductionPracticeError.recoveryRequired(result.error ?? result.status.rawValue)
      }
    }
  }
}
#endif
