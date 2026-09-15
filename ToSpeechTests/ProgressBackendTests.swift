import AVFAudio
import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import ToSpeech

@Suite(.serialized)
struct ProgressBackendTests {
  /// The production Progress model reads real committed takes from the database, maps
  /// them into the domain shape the D03 layout consumes, and numbers them per sentence.
  /// These takes have no assessment jobs, so their `assessments` stay empty (scores are
  /// only attached when a real pronunciation job exists — see the aggregation tests).
  @MainActor
  @Test func progressModelMapsRealTakesForUnassessedHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)

    _ = try await matchingTake(fixture: fixture, outcome: .complete)
    _ = try await matchingTake(fixture: fixture, outcome: .complete)
    _ = try await matchingTake(fixture: fixture, outcome: .noSpeech)

    let importer = ProductionImportService(
      database: fixture.database, paths: fixture.paths, usesSpeechFallback: false)
    let practice = ProductionPracticeService(database: fixture.database, paths: fixture.paths)
    let model = ProductionProgressModel(importService: importer, practiceService: practice)

    await model.load(lessonID: fixture.target.lessonID.uuidString, accent: .us)

    #expect(model.error == nil)
    #expect(model.hasLoaded)
    #expect(model.loadedLessonID == fixture.target.lessonID.uuidString)

    let lesson = try #require(
      model.lessons.first { $0.id == fixture.target.lessonID.uuidString })
    #expect(lesson.sentences.count == 1)
    #expect(lesson.duration >= 0)
    // Header accent follows the chosen reference accent, not a hardcoded value.
    #expect(lesson.accent == .us)

    #expect(model.takes.count == 3)
    // Numbered 1…n within the sentence by capture time.
    #expect(Set(model.takes.map(\.number)) == [1, 2, 3])
    // The recorded sentence revision is preserved (never mixed with a different one).
    #expect(model.takes.allSatisfy { $0.sourceSnapshot.revision == 1 })
    #expect(model.takes.allSatisfy { $0.sourceSnapshot.text == "Practice target" })
    #expect(model.takes.allSatisfy { $0.lessonID == fixture.target.lessonID.uuidString })
    // Takes without an assessment job carry no assessment (and no fabricated score).
    #expect(model.takes.allSatisfy { $0.assessments.isEmpty })
    // A no-speech take is retained in history, not dropped.
    #expect(model.takes.contains { $0.outcome == .noSpeech })
  }

  @MainActor
  @Test func progressModelIsEmptyWhenNoLessonsExist() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let importer = ProductionImportService(
      database: database, paths: paths, usesSpeechFallback: false)
    let practice = ProductionPracticeService(database: database, paths: paths)
    let model = ProductionProgressModel(importService: importer, practiceService: practice)

    await model.load()

    #expect(model.error == nil)
    #expect(model.hasLoaded)
    #expect(model.lessons.isEmpty)
    #expect(model.takes.isEmpty)
    #expect(model.loadedLessonID == nil)
  }

  // MARK: - Take-level score aggregation (pure)

  @MainActor @Test func overallScoreAveragesOnlyScoredPhones() {
    let evidence = makeEvidence(words: [
      makeWord(supported: true, phones: [
        makePhone(0, .scored, score: 80), makePhone(1, .scored, score: 90),
        makePhone(2, .scored, score: 70),
        // Excluded: gated-out phone still carries a number but is not `.scored`.
        makePhone(3, .referenceUncertain, score: 5),
      ])
    ])
    #expect(ProductionProgressModel.overallScore(evidence) == 80)
  }

  @MainActor @Test func overallScoreIsNilWithoutScoredPhones() {
    // No speech / other engine: no phone carries a numeric scored value → never zero.
    let unsupported = makeEvidence(words: [
      makeWord(supported: false, phones: [makePhone(0, .scored, score: 95)])
    ])
    #expect(ProductionProgressModel.overallScore(unsupported) == nil)

    let categorical = makeEvidence(words: [
      makeWord(supported: true, phones: [makePhone(0, .matched, score: nil)])
    ])
    #expect(ProductionProgressModel.overallScore(categorical) == nil)
  }

  @MainActor @Test func assessmentResultsCarryRealProvenanceAndScore() {
    let complete = makeJob(
      status: .complete, provenance: "Phone Scorer E16 · abc123", accent: .us,
      result: makeEvidence(words: [
        makeWord(supported: true, phones: [
          makePhone(0, .scored, score: 60), makePhone(1, .scored, score: 84),
        ])
      ]))
    let unrecognized = makeJob(
      status: .unrecognized, provenance: "Phone Scorer E16 · abc123", accent: .us, result: nil)

    let results = ProductionProgressModel.assessmentResults(jobs: [complete, unrecognized])

    #expect(results.count == 2)
    let scored = try! #require(results.first { $0.id == complete.id.uuidString })
    #expect(scored.engine == .phone)
    #expect(scored.accent == .us)
    #expect(scored.status == .complete)
    #expect(scored.configuration == "Phone Scorer E16 · abc123")
    #expect(scored.score == 72)  // (60 + 84) / 2
    // No-speech job: retained with provenance, but never a fabricated score or zero.
    let empty = try! #require(results.first { $0.id == unrecognized.id.uuidString })
    #expect(empty.status == .failed)
    #expect(empty.score == nil)
  }

  private func makePhone(_ id: Int, _ kind: PhoneDifference.Kind, score: Double?)
    -> PhoneDifference
  {
    PhoneDifference(id: id, kind: kind, expected: "p", observed: "p", start: nil, end: nil, score: score)
  }

  private func makeWord(supported: Bool, phones: [PhoneDifference]) -> WordPronunciationEvidence {
    WordPronunciationEvidence(
      target: PronunciationWordTarget(
        id: "w\(supported)", text: "word", variants: [], dictionarySources: [], sourceStart: nil,
        sourceEnd: nil),
      referenceIPA: nil, phones: phones, supported: supported)
  }

  private func makeEvidence(words: [WordPronunciationEvidence]) -> PronunciationEvidence {
    PronunciationEvidence(words: words, duration: 1, recognizedPhones: [])
  }

  private func makeJob(
    status: PronunciationJob.Status, provenance: String, accent: ReferenceAccent,
    result: PronunciationEvidence?
  ) -> PronunciationJob {
    PronunciationJob(
      id: UUID(), takeID: UUID(),
      target: ProductionPracticeTargetSnapshot(
        lessonID: UUID(), lessonGeneration: 0, segmentID: UUID(), segmentRevisionID: UUID(),
        audioAssetID: UUID(), sampleRate: 44_100, startFrame: 0, endFrame: 4_410, text: "t",
        scope: .sentence, wordIDs: []),
      words: [], accent: accent, provenance: provenance, sourceAudioChecksum: nil,
      audioChecksum: "checksum", createdAt: Date(), status: status, result: result)
  }

  // MARK: - Fixtures (mirrors ProductionPersistenceTests helpers)

  private func matchingTake(
    fixture: (paths: BackendPaths, database: ProductionDatabase, target: ProductionPracticeTarget),
    outcome: CaptureOutcome
  ) async throws -> ProductionStoredTake {
    let targetJSON = String(
      decoding: try JSONEncoder().encode(fixture.target.snapshot), as: UTF8.self)
    let ids = try await fixture.database.beginPracticeCapture(
      target: fixture.target, sessionID: nil, sourceSpeed: 0.85, targetJSON: targetJSON)
    let handle = ProductionCaptureHandle(
      sessionID: ids.sessionID, roundID: ids.roundID, takeID: ids.takeID, target: fixture.target,
      sourceSpeed: 0.85,
      stagingURL: fixture.paths.takeStaging.appendingPathComponent("\(ids.takeID.uuidString).caf"),
      finalURL: fixture.paths.finalTakes.appendingPathComponent("\(ids.takeID.uuidString).caf"),
      manifestURL: fixture.paths.takeStaging.appendingPathComponent("\(ids.takeID.uuidString).json"))
    try writeAudioFixture(to: handle.finalURL)
    let checksum = SHA256.hash(data: try Data(contentsOf: handle.finalURL)).map {
      String(format: "%02x", $0)
    }.joined()
    try await fixture.database.commitPracticeTake(
      handle: handle, assetID: UUID(),
      relativePath: "Takes/Final/\(ids.takeID.uuidString).caf", checksum: checksum,
      sampleRate: 44_100, frameCount: 4_410, outcome: outcome)
    return try #require(
      try await fixture.database.practiceTakes(lessonID: fixture.target.lessonID).last)
  }

  private func preparedPracticeFixture(root: URL) async throws -> (
    paths: BackendPaths, database: ProductionDatabase, target: ProductionPracticeTarget
  ) {
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("practice-source.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let importer = ProductionImportService(
      database: database, paths: paths, usesSpeechFallback: false)
    let job = try await importer.submit(
      .localAudio(url: source, securityScoped: false, titleOverride: "Practice fixture"))
    for _ in 0..<200 {
      if try await database.lesson(id: job.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try await database.lesson(id: job.lessonID).lifecycle == .ready)

    var raw: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let connection = try #require(raw)
    defer { sqlite3_close_v2(connection) }
    var query: OpaquePointer?
    let assetQuery =
      "SELECT current_audio_asset_id FROM lessons WHERE id = '\(job.lessonID.uuidString)'"
    #expect(sqlite3_prepare_v2(connection, assetQuery, -1, &query, nil) == SQLITE_OK)
    let statement = try #require(query)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let assetID = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))
    sqlite3_finalize(statement)
    let audioAssetID = try #require(assetID)
    let segmentID = UUID()
    let revisionID = UUID()
    let sql = """
      INSERT INTO segments (id, lesson_id, ordinal) VALUES ('\(segmentID.uuidString)', '\(job.lessonID.uuidString)', 0);
      INSERT INTO segment_revisions (id, segment_id, revision, text, content_key, reference_key, audio_asset_id, start_frame, end_frame, tokens_schema_version, tokens_json, baseline_json, created_at)
      SELECT '\(revisionID.uuidString)', '\(segmentID.uuidString)', 1, 'Practice target', 'content', 'reference', id, 0, frame_count, 1, '[{"id":"practice-word","text":"Practice","needsTimingReview":true},{"id":"target-word","text":"target","needsTimingReview":true}]', '{"source":"whisper","cueStartFrame":0,"cueEndFrame":4410,"sentenceTimingNeedsReview":false,"wordTimingNeedsReview":false}', 1800000000 FROM media_assets WHERE id = '\(audioAssetID.uuidString)';
      UPDATE segments SET current_revision_id = '\(revisionID.uuidString)' WHERE id = '\(segmentID.uuidString)';
      """
    #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    let target = try #require(
      try await database.practiceTarget(lessonID: job.lessonID, paths: paths))
    return (paths, database, target)
  }

  private func writeAudioFixture(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    guard let channel = buffer.floatChannelData?[0] else { return }
    for frame in 0..<Int(buffer.frameLength) {
      channel[frame] = sin(Float(frame) * 0.05) * 0.1
    }
    try file.write(from: buffer)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToSpeech-progress-test-\(UUID().uuidString)", isDirectory: true)
  }
}
