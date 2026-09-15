import Foundation
import SQLite3

enum ProductionDatabaseError: Error, Equatable, LocalizedError {
  case open(String)
  case execute(String)
  case constraint(String)
  case unsupportedSchema(found: Int, supported: Int)
  case missingLesson(UUID)
  case staleLessonGeneration(expected: Int)

  var errorDescription: String? {
    switch self {
    case .open(let message): "Could not open the local database: \(message)"
    case .execute(let message): "Local database operation failed: \(message)"
    case .constraint(let message): "Local data did not satisfy a required constraint: \(message)"
    case .unsupportedSchema(let found, let supported):
      "This database uses schema \(found), newer than the app supports (\(supported))."
    case .missingLesson(let id): "Lesson \(id.uuidString) no longer exists."
    case .staleLessonGeneration(let expected):
      "Lesson changed while the operation was running (expected generation \(expected))."
    }
  }
}

struct EngineReleaseRecord: Equatable, Sendable {
  let id: UUID
  let engineKey: String
  let version: String
  let status: String
  let relativePath: String?
}

actor ProductionDatabase {
  static let currentSchemaVersion = 4

  // SQLite's OpaquePointer is not Sendable. The wrapper owns only its lifetime;
  // every database operation remains serialized by ProductionDatabase's actor.
  private final class SQLiteHandle: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { sqlite3_close_v2(raw) }
  }

  private let connection: SQLiteHandle

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &opened,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil)
    guard result == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
      if let opened { sqlite3_close_v2(opened) }
      throw ProductionDatabaseError.open(message)
    }

    let connection = SQLiteHandle(opened)
    do {
      sqlite3_busy_timeout(opened, 5_000)
      try Self.execute(on: opened, sql: "PRAGMA foreign_keys = ON")
      try Self.migrate(opened)
      try Self.execute(on: opened, sql: "PRAGMA journal_mode = WAL")
      try Self.execute(on: opened, sql: "PRAGMA synchronous = FULL")
    } catch {
      throw error
    }
    self.connection = connection
  }

  func schemaVersion() throws -> Int {
    try scalarInt("PRAGMA user_version")
  }

  func foreignKeysEnabled() throws -> Bool {
    try scalarInt("PRAGMA foreign_keys") == 1
  }

  func integrityCheck() throws -> String {
    try scalarText("PRAGMA integrity_check")
  }

  @discardableResult
  func insertLesson(_ input: NewLesson) throws -> StoredLesson {
    let provider = input.provider.trimmingCharacters(in: .whitespacesAndNewlines)
    let externalID = input.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty, !externalID.isEmpty, !title.isEmpty else {
      throw ProductionDatabaseError.constraint("provider, external ID and title must not be empty")
    }

    let sql = """
      INSERT INTO lessons (
        id, provider, external_id, source_url, title, author,
        lifecycle, generation, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, 'preparing', 1, ?, ?)
      """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bind(input.id.uuidString, to: 1, in: statement)
    bind(provider, to: 2, in: statement)
    bind(externalID, to: 3, in: statement)
    bind(input.sourceURL?.absoluteString, to: 4, in: statement)
    bind(title, to: 5, in: statement)
    bind(input.author, to: 6, in: statement)
    sqlite3_bind_double(statement, 7, input.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 8, input.createdAt.timeIntervalSince1970)
    try stepDone(statement)
    return try lesson(id: input.id)
  }

  func lesson(id: UUID) throws -> StoredLesson {
    let statement = try prepare(
      """
      SELECT id, provider, external_id, source_url, title, author,
             lifecycle, generation, created_at, updated_at
      FROM lessons WHERE id = ?
      """)
    defer { sqlite3_finalize(statement) }
    bind(id.uuidString, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw ProductionDatabaseError.missingLesson(id)
    }
    return try decodeLesson(statement)
  }

  func lesson(provider: String, externalID: String) throws -> StoredLesson? {
    let statement = try prepare("SELECT id FROM lessons WHERE provider = ? AND external_id = ?")
    defer { sqlite3_finalize(statement) }
    bind(provider, to: 1, in: statement)
    bind(externalID, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      let text = columnText(statement, 0), let id = UUID(uuidString: text) else { return nil }
    return try lesson(id: id)
  }

  func lessonCount() throws -> Int {
    try scalarInt("SELECT COUNT(*) FROM lessons")
  }

  @discardableResult
  func markLessonDeleting(id: UUID, expectedGeneration: Int, at date: Date = Date()) throws -> Int {
    let statement = try prepare(
      """
      UPDATE lessons
      SET lifecycle = 'deleting', generation = generation + 1, updated_at = ?
      WHERE id = ? AND generation = ? AND lifecycle != 'deleting'
      """)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
    bind(id.uuidString, to: 2, in: statement)
    sqlite3_bind_int64(statement, 3, sqlite3_int64(expectedGeneration))
    try stepDone(statement)
    if sqlite3_changes(requiredHandle) == 1 { return expectedGeneration + 1 }

    do {
      _ = try lesson(id: id)
      throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
    } catch ProductionDatabaseError.missingLesson {
      throw ProductionDatabaseError.missingLesson(id)
    }
  }

  func librarySummaries(paths: BackendPaths) throws -> [LibraryLessonSummary] {
    let statement = try prepare(
      """
      SELECT l.id, l.title, l.author, l.lifecycle, l.generation, l.created_at,
             a.sample_rate, a.frame_count, t.relative_path,
             EXISTS(
               SELECT 1
               FROM segments s
               JOIN segment_revisions r ON r.id = s.current_revision_id
               JOIN media_assets source ON source.id = r.audio_asset_id AND source.status = 'ready'
               WHERE s.lesson_id = l.id
             ),
             (SELECT COUNT(*) FROM segments s WHERE s.lesson_id = l.id),
             l.provider, l.external_id, l.source_url,
             (SELECT COUNT(*) FROM segments s
              JOIN segment_revisions r ON r.id = s.current_revision_id
              WHERE s.lesson_id = l.id AND
                COALESCE(json_extract(r.baseline_json, '$.wordTimingNeedsReview'), 1) = 1)
      FROM lessons l
      LEFT JOIN media_assets a ON a.id = l.current_audio_asset_id AND a.status = 'ready'
      LEFT JOIN media_assets t ON t.lesson_id = l.id AND t.role = 'thumbnail' AND t.status = 'ready'
      WHERE l.lifecycle != 'deleting'
      ORDER BY l.updated_at DESC
      """)
    defer { sqlite3_finalize(statement) }
    var summaries: [LibraryLessonSummary] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let title = columnText(statement, 1), let lifecycleText = columnText(statement, 3),
        let lifecycle = LessonLifecycle(rawValue: lifecycleText)
      else { throw ProductionDatabaseError.execute("Library summary row is invalid") }
      let sampleRate = Int(sqlite3_column_int64(statement, 6))
      let frameCount = Int(sqlite3_column_int64(statement, 7))
      let duration =
        sampleRate > 0 && frameCount > 0 ? Double(frameCount) / Double(sampleRate) : nil
      let thumbnail = columnText(statement, 8).flatMap { relativePath in
        Self.safeManagedURL(relativePath, under: paths.root)
      }
      summaries.append(
        LibraryLessonSummary(
          id: id, title: title, author: columnText(statement, 2), lifecycle: lifecycle,
          generation: Int(sqlite3_column_int64(statement, 4)), duration: duration,
          thumbnailURL: thumbnail,
          youtubeVisualSource: YouTubeVisualSource(
            provider: columnText(statement, 11) ?? "", externalID: columnText(statement, 12) ?? "",
            sourceURL: columnText(statement, 13).flatMap(URL.init(string:))),
          isPracticeReady: sqlite3_column_int64(statement, 9) == 1,
          preparedSentenceCount: Int(sqlite3_column_int64(statement, 10)),
          wordTimingReviewCount: Int(sqlite3_column_int64(statement, 14)),
          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
    }
    return summaries
  }

  func persistImportJob(
    id: UUID, lessonID: UUID, expectedGeneration: Int, runToken: UUID, inputJSON: String,
    checkpointJSON: String,
    at date: Date = Date()
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO jobs (id, kind, idempotency_key, expected_generation, input_schema_version, input_json, status, checkpoint_json, created_at, updated_at)
      VALUES (?, 'import', ?, ?, 1, ?, 'running', ?, ?, ?)
      """)
    defer { sqlite3_finalize(statement) }
    bind(id.uuidString, to: 1, in: statement)
    bind("import:\(lessonID.uuidString)", to: 2, in: statement)
    sqlite3_bind_int64(statement, 3, sqlite3_int64(expectedGeneration))
    bind(inputJSON, to: 4, in: statement)
    bind(checkpointJSON, to: 5, in: statement)
    sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
    sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
    try stepDone(statement)
    let attempt = try prepare(
      "INSERT INTO job_attempts (id, job_id, attempt, run_token, status, started_at) VALUES (?, ?, 1, ?, 'running', ?)"
    )
    defer { sqlite3_finalize(attempt) }
    bind(UUID().uuidString, to: 1, in: attempt)
    bind(id.uuidString, to: 2, in: attempt)
    bind(runToken.uuidString, to: 3, in: attempt)
    sqlite3_bind_double(attempt, 4, date.timeIntervalSince1970)
    try stepDone(attempt)
  }

  func checkpointImportJob(
    id: UUID, expectedGeneration: Int, runToken: UUID, status: String, checkpointJSON: String,
    at date: Date = Date()
  ) throws {
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let statement = try prepare(
        "UPDATE jobs SET status = ?, checkpoint_json = ?, updated_at = ? WHERE id = ? AND expected_generation = ? AND EXISTS (SELECT 1 FROM job_attempts WHERE job_id = ? AND run_token = ? AND status = 'running') AND EXISTS (SELECT 1 FROM lessons WHERE id = json_extract(input_json, '$.lessonID') AND generation = ? AND lifecycle != 'deleting')"
      )
      defer { sqlite3_finalize(statement) }
      bind(status, to: 1, in: statement)
      bind(checkpointJSON, to: 2, in: statement)
      sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
      bind(id.uuidString, to: 4, in: statement)
      sqlite3_bind_int64(statement, 5, sqlite3_int64(expectedGeneration))
      bind(id.uuidString, to: 6, in: statement)
      bind(runToken.uuidString, to: 7, in: statement)
      sqlite3_bind_int64(statement, 8, sqlite3_int64(expectedGeneration))
      try stepDone(statement)
      guard sqlite3_changes(requiredHandle) == 1 else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      if status == "failed" || status == "cancelled" {
        let lesson = try prepare(
          "UPDATE lessons SET lifecycle = 'failed', updated_at = ? WHERE id = (SELECT json_extract(input_json, '$.lessonID') FROM jobs WHERE id = ?) AND generation = ?"
        )
        defer { sqlite3_finalize(lesson) }
        sqlite3_bind_double(lesson, 1, date.timeIntervalSince1970)
        bind(id.uuidString, to: 2, in: lesson)
        sqlite3_bind_int64(lesson, 3, sqlite3_int64(expectedGeneration))
        try stepDone(lesson)
        try finishImportAttempt(
          runToken: runToken, status: status, errorJSON: status == "failed" ? checkpointJSON : nil,
          at: date)
      }
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func beginImportRetry(id: UUID, expectedGeneration: Int, at date: Date = Date(), replacementInputJSON: String? = nil) throws -> UUID {
    let runToken = UUID()
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      // Revoke every old run token in the same transaction as the new attempt.
      // An old cancellation/completion must never overwrite the retry's state.
      let revoke = try prepare("UPDATE job_attempts SET status = 'cancelled', finished_at = ? WHERE job_id = ? AND status = 'running'")
      defer { sqlite3_finalize(revoke) }
      sqlite3_bind_double(revoke, 1, date.timeIntervalSince1970)
      bind(id.uuidString, to: 2, in: revoke)
      try stepDone(revoke)
      let attemptNumber = try scalarInt(
        "SELECT COALESCE(MAX(attempt), 0) + 1 FROM job_attempts WHERE job_id = '\(id.uuidString)'")
      let statement = try prepare(
        "INSERT INTO job_attempts (id, job_id, attempt, run_token, status, started_at) VALUES (?, ?, ?, ?, 'running', ?)"
      )
      defer { sqlite3_finalize(statement) }
      bind(UUID().uuidString, to: 1, in: statement)
      bind(id.uuidString, to: 2, in: statement)
      sqlite3_bind_int64(statement, 3, sqlite3_int64(attemptNumber))
      bind(runToken.uuidString, to: 4, in: statement)
      sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
      try stepDone(statement)
      let job = try prepare(
        "UPDATE jobs SET status = 'running', checkpoint_json = json_set(checkpoint_json, '$.phase', 'resolving', '$.detail', NULL), updated_at = ? WHERE id = ? AND expected_generation = ? AND EXISTS (SELECT 1 FROM lessons WHERE id = json_extract(input_json, '$.lessonID') AND generation = ? AND lifecycle != 'deleting')"
      )
      defer { sqlite3_finalize(job) }
      sqlite3_bind_double(job, 1, date.timeIntervalSince1970)
      bind(id.uuidString, to: 2, in: job)
      sqlite3_bind_int64(job, 3, sqlite3_int64(expectedGeneration))
      sqlite3_bind_int64(job, 4, sqlite3_int64(expectedGeneration))
      try stepDone(job)
      guard sqlite3_changes(requiredHandle) == 1 else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      if let replacementInputJSON {
        let replacement = try prepare("UPDATE jobs SET input_json = ? WHERE id = ? AND json_extract(input_json, '$.lessonID') = json_extract(?, '$.lessonID')")
        defer { sqlite3_finalize(replacement) }
        bind(replacementInputJSON, to: 1, in: replacement)
        bind(id.uuidString, to: 2, in: replacement)
        bind(replacementInputJSON, to: 3, in: replacement)
        try stepDone(replacement)
        guard sqlite3_changes(requiredHandle) == 1 else { throw ProductionDatabaseError.constraint("Retry cannot change the lesson identity") }
      }
      let lesson = try prepare(
        "UPDATE lessons SET lifecycle = 'preparing', updated_at = ? WHERE id = (SELECT json_extract(input_json, '$.lessonID') FROM jobs WHERE id = ?) AND generation = ?"
      )
      defer { sqlite3_finalize(lesson) }
      sqlite3_bind_double(lesson, 1, date.timeIntervalSince1970)
      bind(id.uuidString, to: 2, in: lesson)
      sqlite3_bind_int64(lesson, 3, sqlite3_int64(expectedGeneration))
      try stepDone(lesson)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
      return runToken
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func finishImportAttempt(
    runToken: UUID, status: String, errorJSON: String? = nil, at date: Date = Date()
  ) throws {
    let statement = try prepare(
      "UPDATE job_attempts SET status = ?, finished_at = ?, error_json = ? WHERE run_token = ? AND status = 'running'"
    )
    defer { sqlite3_finalize(statement) }
    bind(status, to: 1, in: statement)
    sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
    bind(errorJSON, to: 3, in: statement)
    bind(runToken.uuidString, to: 4, in: statement)
    try stepDone(statement)
  }

  func importAttempts(jobID: UUID) throws -> [ImportAttempt] {
    let statement = try prepare(
      "SELECT id, attempt, run_token, status, started_at, finished_at FROM job_attempts WHERE job_id = ? ORDER BY attempt"
    )
    defer { sqlite3_finalize(statement) }
    bind(jobID.uuidString, to: 1, in: statement)
    var attempts: [ImportAttempt] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let tokenText = columnText(statement, 2), let token = UUID(uuidString: tokenText),
        let status = columnText(statement, 3)
      else { throw ProductionDatabaseError.execute("Stored import attempt row is invalid") }
      let finishedAt =
        sqlite3_column_type(statement, 5) == SQLITE_NULL
        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
      attempts.append(
        ImportAttempt(
          id: id, jobID: jobID, number: Int(sqlite3_column_int64(statement, 1)),
          runToken: token, status: status,
          startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
          finishedAt: finishedAt))
    }
    return attempts
  }

  private static func safeManagedURL(_ relativePath: String, under root: URL) -> URL? {
    guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
      return nil
    }
    return root.appendingPathComponent(relativePath, isDirectory: false)
  }
  func publishImportedAssets(
    lessonID: UUID, expectedGeneration: Int, jobID: UUID, runToken: UUID,
    title: String, author: String?, assets: [MediaAsset], checkpointJSON: String,
    at date: Date = Date()
  ) throws {
    guard let audio = assets.first(where: { $0.role == .sourceAudio }) else {
      throw ProductionDatabaseError.constraint("An import needs one source audio asset")
    }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let lesson = try lesson(id: lessonID)
      guard lesson.generation == expectedGeneration, lesson.lifecycle != .deleting else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      let activeAttempt = try prepare(
        "SELECT COUNT(*) FROM job_attempts WHERE job_id = ? AND run_token = ? AND status = 'running'"
      )
      defer { sqlite3_finalize(activeAttempt) }
      bind(jobID.uuidString, to: 1, in: activeAttempt)
      bind(runToken.uuidString, to: 2, in: activeAttempt)
      guard sqlite3_step(activeAttempt) == SQLITE_ROW, sqlite3_column_int64(activeAttempt, 0) == 1
      else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      for asset in assets {
        let statement = try prepare(
          """
          INSERT INTO media_assets (id, lesson_id, role, relative_path, checksum, format, sample_rate, frame_count, status, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?)
          """)
        bind(asset.id.uuidString, to: 1, in: statement)
        bind(asset.lessonID.uuidString, to: 2, in: statement)
        bind(asset.role.rawValue, to: 3, in: statement)
        bind(asset.relativePath, to: 4, in: statement)
        bind(asset.checksum, to: 5, in: statement)
        bind(asset.format, to: 6, in: statement)
        if let sampleRate = asset.sampleRate {
          sqlite3_bind_int64(statement, 7, sqlite3_int64(sampleRate))
        } else {
          sqlite3_bind_null(statement, 7)
        }
        if let frameCount = asset.frameCount {
          sqlite3_bind_int64(statement, 8, sqlite3_int64(frameCount))
        } else {
          sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_double(statement, 9, asset.createdAt.timeIntervalSince1970)
        try stepDone(statement)
        sqlite3_finalize(statement)
      }
      let lessonStatement = try prepare(
        "UPDATE lessons SET current_audio_asset_id = ?, title = ?, author = ?, lifecycle = 'ready', updated_at = ? WHERE id = ? AND generation = ?"
      )
      bind(audio.id.uuidString, to: 1, in: lessonStatement)
      bind(title, to: 2, in: lessonStatement)
      bind(author, to: 3, in: lessonStatement)
      sqlite3_bind_double(lessonStatement, 4, date.timeIntervalSince1970)
      bind(lessonID.uuidString, to: 5, in: lessonStatement)
      sqlite3_bind_int64(lessonStatement, 6, sqlite3_int64(expectedGeneration))
      try stepDone(lessonStatement)
      sqlite3_finalize(lessonStatement)
      let jobStatement = try prepare(
        "UPDATE jobs SET status = 'succeeded', checkpoint_json = ?, updated_at = ? WHERE id = ? AND expected_generation = ?"
      )
      bind(checkpointJSON, to: 1, in: jobStatement)
      sqlite3_bind_double(jobStatement, 2, date.timeIntervalSince1970)
      bind(jobID.uuidString, to: 3, in: jobStatement)
      sqlite3_bind_int64(jobStatement, 4, sqlite3_int64(expectedGeneration))
      try stepDone(jobStatement)
      sqlite3_finalize(jobStatement)
      try finishImportAttempt(runToken: runToken, status: "succeeded", at: date)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  /// Commits media and the first immutable transcript revisions in one SQLite
  /// transaction. A lesson is only practice-ready after this method succeeds.
  func publishPreparedLesson(
    lessonID: UUID, expectedGeneration: Int, jobID: UUID, runToken: UUID,
    title: String, author: String?, assets: [MediaAsset], segments: [PreparedLessonSegment],
    annotations: [PreparedLessonAnnotation] = [],
    checkpointJSON: String, at date: Date = Date()
  ) throws {
    guard let audio = assets.first(where: { $0.role == .sourceAudio }),
      let frameCount = audio.frameCount, frameCount > 0,
      !segments.isEmpty,
      assets.allSatisfy({ $0.lessonID == lessonID }),
      segments.enumerated().allSatisfy({ index, segment in
        segment.ordinal == index
          && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !segment.contentKey.isEmpty && !segment.referenceKey.isEmpty
          && segment.startFrame >= 0 && segment.endFrame > segment.startFrame
          && segment.endFrame <= frameCount
      })
    else {
      throw ProductionDatabaseError.constraint("Prepared lesson data is invalid")
    }

    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let lesson = try lesson(id: lessonID)
      guard lesson.generation == expectedGeneration, lesson.lifecycle != .deleting else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      let activeAttempt = try prepare(
        "SELECT COUNT(*) FROM job_attempts WHERE job_id = ? AND run_token = ? AND status = 'running'"
      )
      bind(jobID.uuidString, to: 1, in: activeAttempt)
      bind(runToken.uuidString, to: 2, in: activeAttempt)
      guard sqlite3_step(activeAttempt) == SQLITE_ROW, sqlite3_column_int64(activeAttempt, 0) == 1
      else {
        sqlite3_finalize(activeAttempt)
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      sqlite3_finalize(activeAttempt)

      for asset in assets {
        let statement = try prepare(
          """
          INSERT INTO media_assets (id, lesson_id, role, relative_path, checksum, format, sample_rate, frame_count, status, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?)
          """)
        bind(asset.id.uuidString, to: 1, in: statement)
        bind(asset.lessonID.uuidString, to: 2, in: statement)
        bind(asset.role.rawValue, to: 3, in: statement)
        bind(asset.relativePath, to: 4, in: statement)
        bind(asset.checksum, to: 5, in: statement)
        bind(asset.format, to: 6, in: statement)
        if let sampleRate = asset.sampleRate {
          sqlite3_bind_int64(statement, 7, sqlite3_int64(sampleRate))
        } else {
          sqlite3_bind_null(statement, 7)
        }
        if let assetFrameCount = asset.frameCount {
          sqlite3_bind_int64(statement, 8, sqlite3_int64(assetFrameCount))
        } else {
          sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_double(statement, 9, asset.createdAt.timeIntervalSince1970)
        try stepDone(statement)
        sqlite3_finalize(statement)
      }

      for segment in segments {
        let segmentStatement = try prepare(
          "INSERT INTO segments (id, lesson_id, ordinal) VALUES (?, ?, ?)")
        bind(segment.id.uuidString, to: 1, in: segmentStatement)
        bind(lessonID.uuidString, to: 2, in: segmentStatement)
        sqlite3_bind_int64(segmentStatement, 3, sqlite3_int64(segment.ordinal))
        try stepDone(segmentStatement)
        sqlite3_finalize(segmentStatement)

        let revisionID = UUID()
        let revisionStatement = try prepare(
          """
          INSERT INTO segment_revisions (id, segment_id, revision, text, content_key, reference_key, audio_asset_id, start_frame, end_frame, tokens_schema_version, tokens_json, baseline_json, created_at)
          VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
          """)
        bind(revisionID.uuidString, to: 1, in: revisionStatement)
        bind(segment.id.uuidString, to: 2, in: revisionStatement)
        bind(segment.text, to: 3, in: revisionStatement)
        bind(segment.contentKey, to: 4, in: revisionStatement)
        bind(segment.referenceKey, to: 5, in: revisionStatement)
        bind(audio.id.uuidString, to: 6, in: revisionStatement)
        sqlite3_bind_int64(revisionStatement, 7, sqlite3_int64(segment.startFrame))
        sqlite3_bind_int64(revisionStatement, 8, sqlite3_int64(segment.endFrame))
        bind(segment.tokensJSON, to: 9, in: revisionStatement)
        bind(segment.baselineJSON, to: 10, in: revisionStatement)
        sqlite3_bind_double(revisionStatement, 11, date.timeIntervalSince1970)
        try stepDone(revisionStatement)
        sqlite3_finalize(revisionStatement)

        let currentRevision = try prepare(
          "UPDATE segments SET current_revision_id = ? WHERE id = ?")
        bind(revisionID.uuidString, to: 1, in: currentRevision)
        bind(segment.id.uuidString, to: 2, in: currentRevision)
        try stepDone(currentRevision)
        sqlite3_finalize(currentRevision)

        for annotation in annotations where annotation.segmentID == segment.id {
          let annotationStatement = try prepare(
            """
            INSERT INTO annotations (id, revision_id, kind, lookup_key, source, schema_version, automatic_value, created_at)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?)
            """)
          bind(UUID().uuidString, to: 1, in: annotationStatement)
          bind(revisionID.uuidString, to: 2, in: annotationStatement)
          bind(annotation.kind.rawValue, to: 3, in: annotationStatement)
          bind(annotation.lookupKey, to: 4, in: annotationStatement)
          bind(annotation.source, to: 5, in: annotationStatement)
          bind(annotation.automaticValue, to: 6, in: annotationStatement)
          sqlite3_bind_double(annotationStatement, 7, date.timeIntervalSince1970)
          try stepDone(annotationStatement)
          sqlite3_finalize(annotationStatement)
        }
      }

      let lessonStatement = try prepare(
        "UPDATE lessons SET current_audio_asset_id = ?, title = ?, author = ?, lifecycle = 'ready', updated_at = ? WHERE id = ? AND generation = ?"
      )
      bind(audio.id.uuidString, to: 1, in: lessonStatement)
      bind(title, to: 2, in: lessonStatement)
      bind(author, to: 3, in: lessonStatement)
      sqlite3_bind_double(lessonStatement, 4, date.timeIntervalSince1970)
      bind(lessonID.uuidString, to: 5, in: lessonStatement)
      sqlite3_bind_int64(lessonStatement, 6, sqlite3_int64(expectedGeneration))
      try stepDone(lessonStatement)
      sqlite3_finalize(lessonStatement)

      let jobStatement = try prepare(
        "UPDATE jobs SET status = 'succeeded', checkpoint_json = ?, updated_at = ? WHERE id = ? AND expected_generation = ?"
      )
      bind(checkpointJSON, to: 1, in: jobStatement)
      sqlite3_bind_double(jobStatement, 2, date.timeIntervalSince1970)
      bind(jobID.uuidString, to: 3, in: jobStatement)
      sqlite3_bind_int64(jobStatement, 4, sqlite3_int64(expectedGeneration))
      try stepDone(jobStatement)
      sqlite3_finalize(jobStatement)
      try finishImportAttempt(runToken: runToken, status: "succeeded", at: date)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func unfinishedImportJobs() throws -> [StoredImportJob] {
    let statement = try prepare(
      "SELECT id, expected_generation, input_json, checkpoint_json, status, (SELECT run_token FROM job_attempts WHERE job_id = jobs.id ORDER BY attempt DESC LIMIT 1) FROM jobs WHERE kind = 'import' AND status != 'succeeded'"
    )
    defer { sqlite3_finalize(statement) }
    var jobs: [StoredImportJob] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let inputJSON = columnText(statement, 2), let checkpointJSON = columnText(statement, 3),
        let status = columnText(statement, 4), let runTokenText = columnText(statement, 5),
        let runToken = UUID(uuidString: runTokenText)
      else { throw ProductionDatabaseError.execute("Stored import job row is invalid") }
      jobs.append(
        StoredImportJob(
          id: id, expectedGeneration: Int(sqlite3_column_int64(statement, 1)),
          inputJSON: inputJSON, runToken: runToken, checkpointJSON: checkpointJSON, status: status))
    }
    return jobs
  }
  /// Every lesson's stored source audio, for one-off maintenance passes.
  func sourceAudioAssets() throws -> [MediaAsset] {
    let statement = try prepare(
      "SELECT id, lesson_id, relative_path, checksum, format, sample_rate, frame_count, created_at FROM media_assets WHERE role = 'source_audio' AND status = 'ready' ORDER BY created_at"
    )
    defer { sqlite3_finalize(statement) }
    var assets: [MediaAsset] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let lessonText = columnText(statement, 1), let lessonID = UUID(uuidString: lessonText),
        let path = columnText(statement, 2), let checksum = columnText(statement, 3)
      else { throw ProductionDatabaseError.execute("Stored media asset row is invalid") }
      assets.append(
        MediaAsset(
          id: id, lessonID: lessonID, role: .sourceAudio, relativePath: path, checksum: checksum,
          format: columnText(statement, 4),
          sampleRate: sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 5)),
          frameCount: sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 6)),
          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))))
    }
    return assets
  }

  /// Records the bytes now stored for a re-encoded source file.
  func updateSourceAudioAsset(id: UUID, checksum: String, sampleRate: Int, frameCount: Int) throws {
    let statement = try prepare(
      "UPDATE media_assets SET checksum = ?, sample_rate = ?, frame_count = ? WHERE id = ? AND role = 'source_audio'")
    defer { sqlite3_finalize(statement) }
    bind(checksum, to: 1, in: statement)
    sqlite3_bind_int64(statement, 2, sqlite3_int64(sampleRate))
    sqlite3_bind_int64(statement, 3, sqlite3_int64(frameCount))
    bind(id.uuidString, to: 4, in: statement)
    try stepDone(statement)
    guard sqlite3_changes(requiredHandle) == 1 else {
      throw ProductionDatabaseError.execute("No stored source audio asset with id \(id.uuidString)")
    }
  }

  func assetsForLessonDeletion(lessonID: UUID) throws -> [MediaAsset] {
    let statement = try prepare(
      "SELECT id, role, relative_path, checksum, format, sample_rate, frame_count, created_at FROM media_assets WHERE lesson_id = ?"
    )
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var assets: [MediaAsset] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let roleText = columnText(statement, 1), let role = MediaAsset.Role(rawValue: roleText),
        let path = columnText(statement, 2), let checksum = columnText(statement, 3)
      else { throw ProductionDatabaseError.execute("Stored media asset row is invalid") }
      assets.append(
        MediaAsset(
          id: id, lessonID: lessonID, role: role, relativePath: path, checksum: checksum,
          format: columnText(statement, 4),
          sampleRate: sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 5)),
          frameCount: sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 6)),
          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))))
    }
    return assets
  }

  func completeLessonDeletion(lessonID: UUID, expectedGeneration: Int) throws {
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let lesson = try lesson(id: lessonID)
      guard lesson.lifecycle == .deleting, lesson.generation == expectedGeneration else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: expectedGeneration)
      }
      func executeForLesson(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(lessonID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      try executeForLesson(
        "DELETE FROM assessments WHERE take_id IN (SELECT t.id FROM takes t JOIN practice_rounds r ON r.id = t.round_id JOIN practice_sessions s ON s.id = r.session_id WHERE s.lesson_id = ?)"
      )
      try executeForLesson(
        "DELETE FROM takes WHERE round_id IN (SELECT r.id FROM practice_rounds r JOIN practice_sessions s ON s.id = r.session_id WHERE s.lesson_id = ?)"
      )
      try executeForLesson(
        "DELETE FROM practice_rounds WHERE session_id IN (SELECT id FROM practice_sessions WHERE lesson_id = ?)"
      )
      try executeForLesson("DELETE FROM practice_sessions WHERE lesson_id = ?")
      try executeForLesson(
        "DELETE FROM annotations WHERE revision_id IN (SELECT r.id FROM segment_revisions r JOIN segments s ON s.id = r.segment_id WHERE s.lesson_id = ?)"
      )
      try executeForLesson("UPDATE segments SET current_revision_id = NULL WHERE lesson_id = ?")
      try executeForLesson(
        "DELETE FROM segment_revisions WHERE segment_id IN (SELECT id FROM segments WHERE lesson_id = ?)"
      )
      try executeForLesson("DELETE FROM segments WHERE lesson_id = ?")
      let key = "import:\(lessonID.uuidString)"
      let deleteAttempts = try prepare(
        "DELETE FROM job_attempts WHERE job_id IN (SELECT id FROM jobs WHERE idempotency_key = ?)")
      bind(key, to: 1, in: deleteAttempts)
      try stepDone(deleteAttempts)
      sqlite3_finalize(deleteAttempts)
      let deleteJobs = try prepare("DELETE FROM jobs WHERE idempotency_key = ?")
      bind(key, to: 1, in: deleteJobs)
      try stepDone(deleteJobs)
      sqlite3_finalize(deleteJobs)
      try executeForLesson("UPDATE lessons SET current_audio_asset_id = NULL WHERE id = ?")
      try executeForLesson("DELETE FROM media_assets WHERE lesson_id = ?")
      let lessonDelete = try prepare("DELETE FROM lessons WHERE id = ? AND generation = ?")
      bind(lessonID.uuidString, to: 1, in: lessonDelete)
      sqlite3_bind_int64(lessonDelete, 2, sqlite3_int64(expectedGeneration))
      try stepDone(lessonDelete)
      sqlite3_finalize(lessonDelete)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }
  func deletingLessons() throws -> [DeletingLesson] {
    let statement = try prepare("SELECT id, generation FROM lessons WHERE lifecycle = 'deleting'")
    defer { sqlite3_finalize(statement) }
    var lessons: [DeletingLesson] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = columnText(statement, 0), let id = UUID(uuidString: text) else {
        throw ProductionDatabaseError.execute("Deleting lesson row is invalid")
      }
      lessons.append(DeletingLesson(id: id, generation: Int(sqlite3_column_int64(statement, 1))))
    }
    return lessons
  }

  func practiceTarget(lessonID: UUID, paths: BackendPaths) throws -> ProductionPracticeTarget? {
    try practiceTargets(lessonID: lessonID, paths: paths).first
  }

  func practiceTargets(lessonID: UUID, paths: BackendPaths) throws -> [ProductionPracticeTarget] {
    let statement = try prepare(
      """
      SELECT l.generation, s.id, r.id, a.id, a.relative_path, a.sample_rate,
             r.start_frame, r.end_frame, r.text, a.frame_count, r.overrides_json,
             LEAD(r.start_frame) OVER (PARTITION BY a.id ORDER BY r.start_frame, s.ordinal)
      FROM lessons l
      JOIN segments s ON s.lesson_id = l.id
      JOIN segment_revisions r ON r.id = s.current_revision_id
      JOIN media_assets a ON a.id = r.audio_asset_id AND a.status = 'ready'
      WHERE l.id = ? AND l.lifecycle = 'ready'
      ORDER BY s.ordinal
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var targets: [ProductionPracticeTarget] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let segmentText = columnText(statement, 1),
        let segmentID = UUID(uuidString: segmentText),
        let revisionText = columnText(statement, 2),
        let revisionID = UUID(uuidString: revisionText),
        let assetText = columnText(statement, 3), let assetID = UUID(uuidString: assetText),
        let relativePath = columnText(statement, 4),
        let audioURL = Self.safeManagedURL(relativePath, under: paths.root),
        let text = columnText(statement, 8)
      else { throw ProductionDatabaseError.execute("Prepared practice target row is invalid") }
      var target = ProductionPracticeTarget(
        lessonID: lessonID, lessonGeneration: Int(sqlite3_column_int64(statement, 0)),
        segmentID: segmentID, segmentRevisionID: revisionID, audioAssetID: assetID,
        audioURL: audioURL, sampleRate: Int(sqlite3_column_int64(statement, 5)),
        startFrame: Int(sqlite3_column_int64(statement, 6)),
        endFrame: Int(sqlite3_column_int64(statement, 7)), text: text,
        scope: .sentence, wordIDs: [])
      try target.validate()
      guard target.endFrame <= Int(sqlite3_column_int64(statement, 9)) else {
        throw ProductionDatabaseError.constraint("Practice target exceeds source audio")
      }
      target.sourcePlaybackEndFrame = SentencePlaybackBoundary.endFrame(
        sentenceEnd: target.endFrame, sampleRate: target.sampleRate,
        audioFrameCount: Int(sqlite3_column_int64(statement, 9)),
        nextSentenceStart: sqlite3_column_type(statement, 11) == SQLITE_NULL
          ? nil : Int(sqlite3_column_int64(statement, 11)),
        hasTimingOverride: columnData(statement, 10).map { data in
          (try? JSONDecoder().decode(SegmentTimingRevisionDraft.self, from: data))?.timingTranscription == nil
        } ?? false)
      targets.append(target)
    }
    return targets
  }

  /// Loads the current revision, including the data required by the native
  /// sentence/word interface. The audio target is built by the existing
  /// guarded query, so this projection cannot point at an unmanaged asset.
  func preparedPracticeSentences(
    lessonID: UUID, paths: BackendPaths
  ) throws -> [ProductionPreparedSentence] {
    let targets = try practiceTargets(lessonID: lessonID, paths: paths)
    let statement = try prepare(
      """
      SELECT s.id, r.id, r.revision, r.tokens_json, r.baseline_json, r.overrides_json
      FROM segments s
      JOIN segment_revisions r ON r.id = s.current_revision_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE s.lesson_id = ? AND l.lifecycle = 'ready'
      ORDER BY s.ordinal
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var values: [ProductionPreparedSentence] = []
    var targetByRevision = Dictionary(uniqueKeysWithValues: targets.map { ($0.segmentRevisionID, $0) })
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let segmentText = columnText(statement, 0), UUID(uuidString: segmentText) != nil,
        let revisionText = columnText(statement, 1), let revisionID = UUID(uuidString: revisionText),
        let tokensData = columnData(statement, 3), let baselineData = columnData(statement, 4),
        let target = targetByRevision.removeValue(forKey: revisionID)
      else { throw ProductionDatabaseError.execute("Prepared practice sentence row is invalid") }
      do {
        values.append(
          ProductionPreparedSentence(
            target: target, revision: Int(sqlite3_column_int64(statement, 2)),
            tokens: try JSONDecoder().decode([TranscriptWordToken].self, from: tokensData),
            baseline: try JSONDecoder().decode(CaptionBaseline.self, from: baselineData),
            annotations: try annotations(revisionID: revisionID),
            hasManualTiming: columnData(statement, 5).map { data in
              (try? JSONDecoder().decode(SegmentTimingRevisionDraft.self, from: data))?.timingTranscription == nil
            } ?? false))
      } catch let error as ProductionDatabaseError {
        throw error
      } catch {
        throw ProductionDatabaseError.execute("Prepared practice sentence data is invalid")
      }
    }
    guard targetByRevision.isEmpty else {
      throw ProductionDatabaseError.execute("Prepared practice sentence revisions are incomplete")
    }
    return values
  }

  func preparationTargets(lessonID: UUID) throws -> [SegmentPreparationTarget] {
    let statement = try prepare(
      """
      SELECT r.id, r.text, r.tokens_json
      FROM segments s
      JOIN segment_revisions r ON r.id = s.current_revision_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE s.lesson_id = ? AND l.lifecycle = 'ready'
      ORDER BY s.ordinal
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var targets: [SegmentPreparationTarget] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let revisionText = columnText(statement, 0),
        let revisionID = UUID(uuidString: revisionText),
        let text = columnText(statement, 1), let tokensData = columnData(statement, 2)
      else { throw ProductionDatabaseError.execute("Prepared segment row is invalid") }
      let tokens: [TranscriptWordToken]
      do { tokens = try JSONDecoder().decode([TranscriptWordToken].self, from: tokensData) } catch {
        throw ProductionDatabaseError.execute("Prepared segment tokens are invalid")
      }
      targets.append(SegmentPreparationTarget(revisionID: revisionID, text: text, tokens: tokens))
    }
    return targets
  }

  /// Current revisions of a ready lesson that carry neither an automatic nor a
  /// manual translation under `lookupKey` ("sentence:<language>").
  func preparationTargets(lessonID: UUID, missingTranslation lookupKey: String) throws -> [SegmentPreparationTarget] {
    let statement = try prepare(
      """
      SELECT r.id, r.text, r.tokens_json
      FROM segments s
      JOIN segment_revisions r ON r.id = s.current_revision_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE s.lesson_id = ? AND l.lifecycle = 'ready'
        AND NOT EXISTS (
          SELECT 1 FROM annotations a
          WHERE a.revision_id = r.id AND a.kind = 'translation' AND a.lookup_key = ?
            AND (a.automatic_value IS NOT NULL OR a.override_value IS NOT NULL))
      ORDER BY s.ordinal
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    bind(lookupKey, to: 2, in: statement)
    var targets: [SegmentPreparationTarget] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let revisionText = columnText(statement, 0),
        let revisionID = UUID(uuidString: revisionText),
        let text = columnText(statement, 1), let tokensData = columnData(statement, 2)
      else { throw ProductionDatabaseError.execute("Prepared segment row is invalid") }
      let tokens: [TranscriptWordToken]
      do { tokens = try JSONDecoder().decode([TranscriptWordToken].self, from: tokensData) } catch {
        throw ProductionDatabaseError.execute("Prepared segment tokens are invalid")
      }
      targets.append(SegmentPreparationTarget(revisionID: revisionID, text: text, tokens: tokens))
    }
    return targets
  }

  func annotations(revisionID: UUID) throws -> [StoredPreparationAnnotation] {
    let statement = try prepare(
      """
      SELECT kind, lookup_key, source, automatic_value, override_value
      FROM annotations WHERE revision_id = ? ORDER BY kind, lookup_key
      """)
    defer { sqlite3_finalize(statement) }
    bind(revisionID.uuidString, to: 1, in: statement)
    var values: [StoredPreparationAnnotation] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let kindText = columnText(statement, 0),
        let kind = PreparationAnnotationKind(rawValue: kindText),
        let lookupKey = columnText(statement, 1), let source = columnText(statement, 2)
      else { throw ProductionDatabaseError.execute("Preparation annotation row is invalid") }
      values.append(
        StoredPreparationAnnotation(
          revisionID: revisionID, kind: kind, lookupKey: lookupKey, source: source,
          automaticValue: columnData(statement, 3), overrideValue: columnData(statement, 4)))
    }
    return values
  }

  /// Automatic jobs may refresh their own value, but never overwrite a manual override.
  func storeAutomaticAnnotation(
    revisionID: UUID, kind: PreparationAnnotationKind, lookupKey: String,
    source: String, value: Data, at date: Date = Date()
  ) throws {
    guard !lookupKey.isEmpty, !source.isEmpty else {
      throw ProductionDatabaseError.constraint("Annotation key and source are required")
    }
    let statement = try prepare(
      """
      INSERT INTO annotations (id, revision_id, kind, lookup_key, source, schema_version, automatic_value, created_at)
      SELECT ?, r.id, ?, ?, ?, 1, ?, ?
      FROM segment_revisions r JOIN segments s ON s.current_revision_id = r.id
      WHERE r.id = ?
      ON CONFLICT(revision_id, kind, lookup_key) DO UPDATE SET
        source = excluded.source,
        schema_version = excluded.schema_version,
        automatic_value = excluded.automatic_value,
        created_at = excluded.created_at
      """)
    defer { sqlite3_finalize(statement) }
    bind(UUID().uuidString, to: 1, in: statement)
    bind(kind.rawValue, to: 2, in: statement)
    bind(lookupKey, to: 3, in: statement)
    bind(source, to: 4, in: statement)
    bind(value, to: 5, in: statement)
    sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
    bind(revisionID.uuidString, to: 7, in: statement)
    try stepDone(statement)
    guard sqlite3_changes(requiredHandle) == 1 else {
      throw ProductionDatabaseError.staleLessonGeneration(expected: 0)
    }
  }

  func storeAnnotationOverride(
    revisionID: UUID, kind: PreparationAnnotationKind, lookupKey: String,
    source: String, value: Data, at date: Date = Date()
  ) throws {
    guard !lookupKey.isEmpty, !source.isEmpty else {
      throw ProductionDatabaseError.constraint("Annotation key and source are required")
    }
    let statement = try prepare(
      """
      INSERT INTO annotations (id, revision_id, kind, lookup_key, source, schema_version, override_value, created_at)
      SELECT ?, r.id, ?, ?, ?, 1, ?, ?
      FROM segment_revisions r JOIN segments s ON s.current_revision_id = r.id
      WHERE r.id = ?
      ON CONFLICT(revision_id, kind, lookup_key) DO UPDATE SET
        source = excluded.source,
        override_value = excluded.override_value,
        created_at = excluded.created_at
      """)
    defer { sqlite3_finalize(statement) }
    bind(UUID().uuidString, to: 1, in: statement)
    bind(kind.rawValue, to: 2, in: statement)
    bind(lookupKey, to: 3, in: statement)
    bind(source, to: 4, in: statement)
    bind(value, to: 5, in: statement)
    sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
    bind(revisionID.uuidString, to: 7, in: statement)
    try stepDone(statement)
    guard sqlite3_changes(requiredHandle) == 1 else {
      throw ProductionDatabaseError.staleLessonGeneration(expected: 0)
    }
  }

  /// Publishes a new immutable revision after an explicit human timing edit.
  /// Existing practice rounds retain their old revision; current practice and
  /// future annotation work see only the newly published revision.
  func publishTimingRevision(
    _ draft: SegmentTimingRevisionDraft, at date: Date = Date()
  ) throws -> StoredTimingRevision {
    guard draft.startFrame >= 0, draft.endFrame > draft.startFrame, !draft.tokens.isEmpty else {
      throw ProductionDatabaseError.constraint("Timing revision range or tokens are invalid")
    }

    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let current = try prepare(
        """
        SELECT s.current_revision_id, r.revision, r.text, r.content_key, r.reference_key,
               r.audio_asset_id, r.tokens_json, r.baseline_json, a.frame_count
        FROM segments s
        JOIN segment_revisions r ON r.id = s.current_revision_id
        JOIN media_assets a ON a.id = r.audio_asset_id AND a.status = 'ready'
        JOIN lessons l ON l.id = s.lesson_id
        WHERE s.id = ? AND l.lifecycle = 'ready'
        """)
      defer { sqlite3_finalize(current) }
      bind(draft.segmentID.uuidString, to: 1, in: current)
      guard sqlite3_step(current) == SQLITE_ROW,
        let previousText = columnText(current, 0),
        let previousRevisionID = UUID(uuidString: previousText),
        previousRevisionID == draft.expectedRevisionID,
        let text = columnText(current, 2), let contentKey = columnText(current, 3),
        let referenceKey = columnText(current, 4), let audioAssetText = columnText(current, 5),
        let audioAssetID = UUID(uuidString: audioAssetText),
        let priorTokensData = columnData(current, 6),
        let baselineData = columnData(current, 7)
      else { throw ProductionDatabaseError.staleLessonGeneration(expected: 0) }
      let frameCount = Int(sqlite3_column_int64(current, 8))
      guard draft.endFrame <= frameCount else {
        throw ProductionDatabaseError.constraint("Timing revision exceeds source audio")
      }

      let priorTokens: [TranscriptWordToken]
      let baseline: CaptionBaseline
      do {
        priorTokens = try JSONDecoder().decode([TranscriptWordToken].self, from: priorTokensData)
        baseline = try JSONDecoder().decode(CaptionBaseline.self, from: baselineData)
      } catch {
        throw ProductionDatabaseError.execute("Current timing revision cannot be decoded")
      }
      guard priorTokens.map(\.id) == draft.tokens.map(\.id),
        priorTokens.map(\.text) == draft.tokens.map(\.text)
      else {
        throw ProductionDatabaseError.constraint("Timing edits cannot change transcript words")
      }

      let hasCompleteWordTiming = draft.tokens.filter { IPAFormatting.isPronounceable($0.text) }.allSatisfy { token in
        guard let start = token.startFrame, let end = token.endFrame else { return false }
        return start >= draft.startFrame && end > start && end <= draft.endFrame
      }
      guard !draft.resolvesTimingReview || hasCompleteWordTiming else {
        throw ProductionDatabaseError.constraint(
          "Every word needs a valid range before timing review can be resolved")
      }

      let newRevisionID = UUID()
      let newRevision = Int(sqlite3_column_int64(current, 1)) + 1
      let newBaseline = baseline.applying(
        startFrame: draft.startFrame, endFrame: draft.endFrame,
        wordTimingNeedsReview: !hasCompleteWordTiming,
        resolvesTimingReview: draft.resolvesTimingReview, timingTranscription: draft.timingTranscription,
        alignment: draft.alignment)
      let revision = try prepare(
        """
        INSERT INTO segment_revisions (
          id, segment_id, revision, text, content_key, reference_key, audio_asset_id,
          start_frame, end_frame, tokens_schema_version, tokens_json, baseline_json,
          overrides_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
        """)
      bind(newRevisionID.uuidString, to: 1, in: revision)
      bind(draft.segmentID.uuidString, to: 2, in: revision)
      sqlite3_bind_int64(revision, 3, sqlite3_int64(newRevision))
      bind(text, to: 4, in: revision)
      bind(contentKey, to: 5, in: revision)
      bind(referenceKey, to: 6, in: revision)
      bind(audioAssetID.uuidString, to: 7, in: revision)
      sqlite3_bind_int64(revision, 8, sqlite3_int64(draft.startFrame))
      sqlite3_bind_int64(revision, 9, sqlite3_int64(draft.endFrame))
      bind(try JSONEncoder().encode(draft.tokens), to: 10, in: revision)
      bind(try JSONEncoder().encode(newBaseline), to: 11, in: revision)
      bind(try JSONEncoder().encode(draft), to: 12, in: revision)
      sqlite3_bind_double(revision, 13, date.timeIntervalSince1970)
      try stepDone(revision)
      sqlite3_finalize(revision)

      let copyAnnotations = try prepare(
        """
        INSERT INTO annotations (
          id, revision_id, kind, lookup_key, source, schema_version,
          automatic_value, override_value, created_at
        )
        SELECT lower(hex(randomblob(16))), ?, kind, lookup_key, source, schema_version,
               automatic_value, override_value, ?
        FROM annotations WHERE revision_id = ?
        """)
      bind(newRevisionID.uuidString, to: 1, in: copyAnnotations)
      sqlite3_bind_double(copyAnnotations, 2, date.timeIntervalSince1970)
      bind(previousRevisionID.uuidString, to: 3, in: copyAnnotations)
      try stepDone(copyAnnotations)
      sqlite3_finalize(copyAnnotations)

      let advanceCurrent = try prepare(
        "UPDATE segments SET current_revision_id = ? WHERE id = ? AND current_revision_id = ?")
      bind(newRevisionID.uuidString, to: 1, in: advanceCurrent)
      bind(draft.segmentID.uuidString, to: 2, in: advanceCurrent)
      bind(previousRevisionID.uuidString, to: 3, in: advanceCurrent)
      try stepDone(advanceCurrent)
      guard sqlite3_changes(requiredHandle) == 1 else {
        throw ProductionDatabaseError.staleLessonGeneration(expected: 0)
      }
      try Self.execute(on: requiredHandle, sql: "COMMIT")
      return StoredTimingRevision(
        segmentID: draft.segmentID, previousRevisionID: previousRevisionID,
        revisionID: newRevisionID, revision: newRevision)
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func beginPracticeCapture(
    target: ProductionPracticeTarget, sessionID existingSessionID: UUID?,
    sourceSpeed: Double, targetJSON: String, at date: Date = Date()
  ) throws -> (sessionID: UUID, roundID: UUID, takeID: UUID) {
    try target.validate()
    guard sourceSpeed.isFinite, sourceSpeed > 0 else {
      throw ProductionDatabaseError.constraint("source speed must be positive")
    }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let targetCheck = try prepare(
        """
        SELECT COUNT(*) FROM lessons l
        JOIN segments s ON s.lesson_id = l.id
        JOIN segment_revisions r ON r.id = s.current_revision_id
        JOIN media_assets a ON a.id = r.audio_asset_id
        WHERE l.id = ? AND l.generation = ? AND l.lifecycle = 'ready'
          AND s.id = ? AND r.id = ? AND a.id = ? AND a.status = 'ready'
          AND r.start_frame = ? AND r.end_frame = ? AND r.text = ? AND a.sample_rate = ?
        """)
      bind(target.lessonID.uuidString, to: 1, in: targetCheck)
      sqlite3_bind_int64(targetCheck, 2, sqlite3_int64(target.lessonGeneration))
      bind(target.segmentID.uuidString, to: 3, in: targetCheck)
      bind(target.segmentRevisionID.uuidString, to: 4, in: targetCheck)
      bind(target.audioAssetID.uuidString, to: 5, in: targetCheck)
      sqlite3_bind_int64(targetCheck, 6, sqlite3_int64(target.startFrame))
      sqlite3_bind_int64(targetCheck, 7, sqlite3_int64(target.endFrame))
      bind(target.text, to: 8, in: targetCheck)
      sqlite3_bind_int64(targetCheck, 9, sqlite3_int64(target.sampleRate))
      guard sqlite3_step(targetCheck) == SQLITE_ROW, sqlite3_column_int64(targetCheck, 0) == 1
      else {
        sqlite3_finalize(targetCheck)
        throw ProductionDatabaseError.staleLessonGeneration(expected: target.lessonGeneration)
      }
      sqlite3_finalize(targetCheck)

      let sessionID = existingSessionID ?? UUID()
      if let existingSessionID {
        let sessionCheck = try prepare(
          "SELECT COUNT(*) FROM practice_sessions WHERE id = ? AND lesson_id = ? AND ended_at IS NULL"
        )
        bind(existingSessionID.uuidString, to: 1, in: sessionCheck)
        bind(target.lessonID.uuidString, to: 2, in: sessionCheck)
        guard sqlite3_step(sessionCheck) == SQLITE_ROW, sqlite3_column_int64(sessionCheck, 0) == 1
        else {
          sqlite3_finalize(sessionCheck)
          throw ProductionDatabaseError.constraint("practice session is unavailable")
        }
        sqlite3_finalize(sessionCheck)
      } else {
        let session = try prepare(
          "INSERT INTO practice_sessions (id, lesson_id, started_at) VALUES (?, ?, ?)")
        bind(sessionID.uuidString, to: 1, in: session)
        bind(target.lessonID.uuidString, to: 2, in: session)
        sqlite3_bind_double(session, 3, date.timeIntervalSince1970)
        try stepDone(session)
        sqlite3_finalize(session)
      }

      let roundID = UUID()
      let round = try prepare(
        "INSERT INTO practice_rounds (id, session_id, segment_revision_id, audio_asset_id, scope, target_schema_version, target_json, source_speed, created_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)"
      )
      bind(roundID.uuidString, to: 1, in: round)
      bind(sessionID.uuidString, to: 2, in: round)
      bind(target.segmentRevisionID.uuidString, to: 3, in: round)
      bind(target.audioAssetID.uuidString, to: 4, in: round)
      bind(target.scope.rawValue, to: 5, in: round)
      bind(targetJSON, to: 6, in: round)
      sqlite3_bind_double(round, 7, sourceSpeed)
      sqlite3_bind_double(round, 8, date.timeIntervalSince1970)
      try stepDone(round)
      sqlite3_finalize(round)

      let takeID = UUID()
      let take = try prepare(
        "INSERT INTO takes (id, round_id, outcome, status, created_at) VALUES (?, ?, 'interrupted', 'writing', ?)"
      )
      bind(takeID.uuidString, to: 1, in: take)
      bind(roundID.uuidString, to: 2, in: take)
      sqlite3_bind_double(take, 3, date.timeIntervalSince1970)
      try stepDone(take)
      sqlite3_finalize(take)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
      return (sessionID, roundID, takeID)
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func markTakeFinalizing(id: UUID) throws {
    let statement = try prepare(
      "UPDATE takes SET status = 'finalizing' WHERE id = ? AND status IN ('writing','finalizing')")
    defer { sqlite3_finalize(statement) }
    bind(id.uuidString, to: 1, in: statement)
    try stepDone(statement)
    guard sqlite3_changes(requiredHandle) == 1 else {
      throw ProductionDatabaseError.constraint("take is not writable")
    }
  }

  func commitPracticeTake(
    handle: ProductionCaptureHandle, assetID: UUID, relativePath: String, checksum: String,
    sampleRate: Int, frameCount: Int, outcome: CaptureOutcome, at date: Date = Date()
  ) throws {
    guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
      !checksum.isEmpty, sampleRate > 0, frameCount > 0
    else { throw ProductionDatabaseError.constraint("take media metadata is invalid") }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let asset = try prepare(
        "INSERT INTO media_assets (id, lesson_id, role, relative_path, checksum, format, sample_rate, frame_count, status, created_at) VALUES (?, ?, 'take_audio', ?, ?, 'caf', ?, ?, 'ready', ?)"
      )
      bind(assetID.uuidString, to: 1, in: asset)
      bind(handle.target.lessonID.uuidString, to: 2, in: asset)
      bind(relativePath, to: 3, in: asset)
      bind(checksum, to: 4, in: asset)
      sqlite3_bind_int64(asset, 5, sqlite3_int64(sampleRate))
      sqlite3_bind_int64(asset, 6, sqlite3_int64(frameCount))
      sqlite3_bind_double(asset, 7, date.timeIntervalSince1970)
      try stepDone(asset)
      sqlite3_finalize(asset)
      let take = try prepare(
        """
        UPDATE takes SET media_asset_id = ?, outcome = ?, duration_frames = ?,
          status = 'ready', committed_at = ?
        WHERE id = ? AND round_id = ? AND status IN ('writing','finalizing')
          AND EXISTS (SELECT 1 FROM lessons WHERE id = ? AND generation = ? AND lifecycle = 'ready')
        """)
      bind(assetID.uuidString, to: 1, in: take)
      bind(outcome.databaseValue, to: 2, in: take)
      sqlite3_bind_int64(take, 3, sqlite3_int64(frameCount))
      sqlite3_bind_double(take, 4, date.timeIntervalSince1970)
      bind(handle.takeID.uuidString, to: 5, in: take)
      bind(handle.roundID.uuidString, to: 6, in: take)
      bind(handle.target.lessonID.uuidString, to: 7, in: take)
      sqlite3_bind_int64(take, 8, sqlite3_int64(handle.target.lessonGeneration))
      try stepDone(take)
      let changed = sqlite3_changes(requiredHandle)
      sqlite3_finalize(take)
      guard changed == 1 else {
        throw ProductionDatabaseError.staleLessonGeneration(
          expected: handle.target.lessonGeneration)
      }
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func practiceTakes(lessonID: UUID) throws -> [ProductionStoredTake] {
    let statement = try prepare(
      """
      SELECT t.id, t.round_id, r.segment_revision_id, r.source_speed, t.outcome, t.status,
             a.relative_path, a.sample_rate, a.frame_count, t.created_at, t.committed_at
      FROM takes t
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN practice_sessions s ON s.id = r.session_id
      LEFT JOIN media_assets a ON a.id = t.media_asset_id
      WHERE s.lesson_id = ? AND t.status != 'discarded' ORDER BY t.created_at
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var result: [ProductionStoredTake] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let roundText = columnText(statement, 1), let roundID = UUID(uuidString: roundText),
        let revisionText = columnText(statement, 2), let revisionID = UUID(uuidString: revisionText),
        let outcomeText = columnText(statement, 4),
        let outcome = CaptureOutcome(databaseValue: outcomeText),
        let status = columnText(statement, 5)
      else { throw ProductionDatabaseError.execute("Stored take row is invalid") }
      result.append(
        ProductionStoredTake(
          id: id, lessonID: lessonID, roundID: roundID, segmentRevisionID: revisionID,
          sourceSpeed: sqlite3_column_double(statement, 3), outcome: outcome, status: status,
          relativePath: columnText(statement, 6),
          sampleRate: sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 7)),
          frameCount: sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 8)),
          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
          committedAt: sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))))
    }
    return result
  }

  func discardPracticeTake(id: UUID) throws {
    let statement = try prepare(
      "UPDATE takes SET status = 'discarded' WHERE id = ? AND status IN ('writing','finalizing','recovery')"
    )
    defer { sqlite3_finalize(statement) }
    bind(id.uuidString, to: 1, in: statement)
    try stepDone(statement)
  }

  /// Marks committed recordings as hidden before their files are removed. A
  /// relaunch can finish records left in this state without exposing missing audio.
  func markPracticeTakesForDeletion(
    ids: Set<UUID>, lessonID: UUID
  ) throws -> [ProductionTakeDeletionRecord] {
    guard !ids.isEmpty else { return [] }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      var records: [ProductionTakeDeletionRecord] = []
      for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
        let statement = try prepare(
          """
          SELECT t.round_id, r.session_id, t.media_asset_id, a.relative_path, t.status
          FROM takes t
          JOIN practice_rounds r ON r.id = t.round_id
          JOIN practice_sessions s ON s.id = r.session_id
          JOIN media_assets a ON a.id = t.media_asset_id
          WHERE t.id = ? AND s.lesson_id = ?
          """)
        bind(id.uuidString, to: 1, in: statement)
        bind(lessonID.uuidString, to: 2, in: statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
          let roundText = columnText(statement, 0), let roundID = UUID(uuidString: roundText),
          let sessionText = columnText(statement, 1), let sessionID = UUID(uuidString: sessionText),
          let assetText = columnText(statement, 2), let assetID = UUID(uuidString: assetText),
          let path = columnText(statement, 3), let status = columnText(statement, 4),
          status == "ready" || status == "discarded"
        else {
          throw ProductionDatabaseError.constraint("A selected recording is no longer available.")
        }
        for job in try contentMatchingJobs().filter({ $0.takeID == id }) where job.isPending {
          throw ProductionDatabaseError.constraint("Wait for the selected recording to finish processing before deleting it.")
        }
        for job in try pronunciationJobs().filter({ $0.takeID == id }) where job.isPending {
          throw ProductionDatabaseError.constraint("Wait for the selected recording to finish processing before deleting it.")
        }
        records.append(.init(takeID: id, roundID: roundID, sessionID: sessionID,
          mediaAssetID: assetID, relativePath: path))
      }
      for record in records {
        let update = try prepare("UPDATE takes SET status = 'discarded' WHERE id = ?")
        bind(record.takeID.uuidString, to: 1, in: update)
        try stepDone(update)
        sqlite3_finalize(update)
      }
      try Self.execute(on: requiredHandle, sql: "COMMIT")
      return records
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func discardedPracticeTakes() throws -> [ProductionTakeDeletionRecord] {
    let statement = try prepare(
      """
      SELECT t.id, t.round_id, r.session_id, t.media_asset_id, a.relative_path
      FROM takes t
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN media_assets a ON a.id = t.media_asset_id
      WHERE t.status = 'discarded' AND t.media_asset_id IS NOT NULL
      ORDER BY t.created_at
      """)
    defer { sqlite3_finalize(statement) }
    var result: [ProductionTakeDeletionRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let takeText = columnText(statement, 0), let takeID = UUID(uuidString: takeText),
        let roundText = columnText(statement, 1), let roundID = UUID(uuidString: roundText),
        let sessionText = columnText(statement, 2), let sessionID = UUID(uuidString: sessionText),
        let assetText = columnText(statement, 3), let assetID = UUID(uuidString: assetText),
        let path = columnText(statement, 4)
      else { throw ProductionDatabaseError.execute("Discarded recording row is invalid") }
      result.append(.init(takeID: takeID, roundID: roundID, sessionID: sessionID,
        mediaAssetID: assetID, relativePath: path))
    }
    return result
  }

  func purgeDiscardedPracticeTakes(_ records: [ProductionTakeDeletionRecord]) throws {
    guard !records.isEmpty else { return }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      for record in records {
        func execute(_ sql: String, id: UUID) throws {
          let statement = try prepare(sql)
          defer { sqlite3_finalize(statement) }
          bind(id.uuidString, to: 1, in: statement)
          try stepDone(statement)
        }
        try execute("DELETE FROM content_matching_jobs WHERE take_id = ?", id: record.takeID)
        try execute("DELETE FROM pronunciation_jobs WHERE take_id = ?", id: record.takeID)
        try execute("DELETE FROM assessments WHERE take_id = ?", id: record.takeID)
        try execute("DELETE FROM takes WHERE id = ? AND status = 'discarded'", id: record.takeID)
        try execute("DELETE FROM practice_rounds WHERE id = ?", id: record.roundID)
        try execute("DELETE FROM media_assets WHERE id = ?", id: record.mediaAssetID)
        try execute(
          "DELETE FROM practice_sessions WHERE id = ? AND NOT EXISTS (SELECT 1 FROM practice_rounds WHERE session_id = practice_sessions.id)",
          id: record.sessionID)
      }
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }
  @discardableResult
  func registerEngineRelease(
    engineKey: String, version: String, capabilityJSON: String, at date: Date = Date()
  ) throws -> UUID {
    guard !engineKey.isEmpty, !version.isEmpty else {
      throw ProductionDatabaseError.constraint("engine key and version are required")
    }
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
      let existing = try prepare(
        "SELECT id FROM engine_releases WHERE engine_key = ? AND version = ?")
      defer { sqlite3_finalize(existing) }
      bind(engineKey, to: 1, in: existing)
      bind(version, to: 2, in: existing)
      if sqlite3_step(existing) == SQLITE_ROW, let text = columnText(existing, 0),
        let id = UUID(uuidString: text)
      {
        try Self.execute(on: requiredHandle, sql: "COMMIT")
        return id
      }
      let id = UUID()
      let insert = try prepare(
        """
        INSERT INTO engine_releases (id, engine_key, version, model_checksum, capability_json, created_at)
        VALUES (?, ?, ?, NULL, ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      bind(id.uuidString, to: 1, in: insert)
      bind(engineKey, to: 2, in: insert)
      bind(version, to: 3, in: insert)
      bind(capabilityJSON, to: 4, in: insert)
      sqlite3_bind_double(insert, 5, date.timeIntervalSince1970)
      try stepDone(insert)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
      return id
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  func setEngineInstallationStatus(
    releaseID: UUID, status: String, relativePath: String? = nil, errorJSON: String? = nil,
    at date: Date = Date()
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO engine_installations (engine_release_id, status, relative_path, installed_at, last_error_json)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(engine_release_id) DO UPDATE SET
        status = excluded.status,
        relative_path = excluded.relative_path,
        installed_at = excluded.installed_at,
        last_error_json = excluded.last_error_json
      """)
    defer { sqlite3_finalize(statement) }
    bind(releaseID.uuidString, to: 1, in: statement)
    bind(status, to: 2, in: statement)
    bind(relativePath, to: 3, in: statement)
    if status == "installed" {
      sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, 4)
    }
    bind(errorJSON, to: 5, in: statement)
    try stepDone(statement)
    guard sqlite3_changes(requiredHandle) == 1 else {
      throw ProductionDatabaseError.constraint("engine installation could not be recorded")
    }
  }

  func engineReleases(engineKey: String) throws -> [EngineReleaseRecord] {
    let statement = try prepare(
      """
      SELECT r.id, r.engine_key, r.version,
             COALESCE(i.status, 'not_installed'), i.relative_path
      FROM engine_releases r
      LEFT JOIN engine_installations i ON i.engine_release_id = r.id
      WHERE r.engine_key = ?
      ORDER BY r.version
      """)
    defer { sqlite3_finalize(statement) }
    bind(engineKey, to: 1, in: statement)
    var records: [EngineReleaseRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
        let key = columnText(statement, 1), let version = columnText(statement, 2),
        let status = columnText(statement, 3)
      else { throw ProductionDatabaseError.execute("Engine release row is invalid") }
      records.append(
        EngineReleaseRecord(
          id: id, engineKey: key, version: version, status: status,
          relativePath: columnText(statement, 4)))
    }
    return records
  }

  private var requiredHandle: OpaquePointer {
    connection.raw
  }

  func dictationProgress(lessonID: UUID) throws -> [DictationProgress] {
    let statement = try prepare("SELECT payload FROM dictation_progress WHERE lesson_id = ?")
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var values: [DictationProgress] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let data = columnData(statement, 0) else {
        throw ProductionDatabaseError.execute("Could not read dictation progress.")
      }
      // One damaged row must not lock the whole lesson out of dictation. It is
      // skipped here and replaced by the next save for that revision.
      guard let value = try? JSONDecoder().decode(DictationProgress.self, from: data),
        (try? value.validate()) != nil
      else { continue }
      values.append(value)
    }
    return values
  }

  func saveDictationProgress(_ value: DictationProgress) throws {
    try value.validate()
    try Self.execute(on: requiredHandle, sql: "BEGIN IMMEDIATE")
    do {
    let target = try prepare("""
      SELECT r.text FROM segment_revisions r
      JOIN segments s ON s.id = r.segment_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE r.id = ? AND s.lesson_id = ? AND l.lifecycle != 'deleting'
      """)
    defer { sqlite3_finalize(target) }
    bind(value.revisionID.uuidString, to: 1, in: target)
    bind(value.lessonID.uuidString, to: 2, in: target)
    guard sqlite3_step(target) == SQLITE_ROW, columnText(target, 0) == value.targetText else {
      throw DictationError.invalidProgress
    }
    if let old = try dictationProgress(lessonID: value.lessonID).first(where: { $0.revisionID == value.revisionID }) {
      guard value.attempts.starts(with: old.attempts) else { throw DictationError.invalidProgress }
    }
    let statement = try prepare("""
      INSERT INTO dictation_progress (revision_id, lesson_id, payload) VALUES (?, ?, ?)
      ON CONFLICT(revision_id) DO UPDATE SET payload = excluded.payload
      """)
    defer { sqlite3_finalize(statement) }
    bind(value.revisionID.uuidString, to: 1, in: statement)
    bind(value.lessonID.uuidString, to: 2, in: statement)
    bind(try JSONEncoder().encode(value), to: 3, in: statement)
    try stepDone(statement)
      try Self.execute(on: requiredHandle, sql: "COMMIT")
    } catch {
      try? Self.execute(on: requiredHandle, sql: "ROLLBACK")
      throw error
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(requiredHandle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else { throw databaseError(for: result) }
    return statement
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else { throw databaseError(for: result) }
  }

  private func scalarInt(_ sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw ProductionDatabaseError.execute(String(cString: sqlite3_errmsg(requiredHandle)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func scalarText(_ sql: String) throws -> String {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0)
    else {
      throw ProductionDatabaseError.execute(String(cString: sqlite3_errmsg(requiredHandle)))
    }
    return String(cString: value)
  }

  private func decodeLesson(_ statement: OpaquePointer) throws -> StoredLesson {
    guard
      let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
      let provider = columnText(statement, 1), let externalID = columnText(statement, 2),
      let title = columnText(statement, 4), let lifecycleText = columnText(statement, 6),
      let lifecycle = LessonLifecycle(rawValue: lifecycleText)
    else {
      throw ProductionDatabaseError.execute("Stored lesson row is invalid")
    }
    return StoredLesson(
      id: id,
      provider: provider,
      externalID: externalID,
      sourceURL: columnText(statement, 3).flatMap(URL.init(string:)),
      title: title,
      author: columnText(statement, 5),
      lifecycle: lifecycle,
      generation: Int(sqlite3_column_int64(statement, 7)),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)))
  }

  private func databaseError(for result: Int32) -> ProductionDatabaseError {
    let message = String(cString: sqlite3_errmsg(requiredHandle))
    let primary = result & 0xFF
    return primary == SQLITE_CONSTRAINT ? .constraint(message) : .execute(message)
  }

  private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_text(
      statement, index, value, -1,
      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }

  private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement, index, bytes.baseAddress, Int32(value.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let value = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: value)
  }

  private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let bytes = sqlite3_column_blob(statement, index)
    else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
  }

  private static func migrate(_ database: OpaquePointer) throws {
    let found = try scalarInt(on: database, sql: "PRAGMA user_version")
    guard found <= currentSchemaVersion else {
      throw ProductionDatabaseError.unsupportedSchema(
        found: found, supported: currentSchemaVersion)
    }
    guard found < currentSchemaVersion else { return }

    try execute(on: database, sql: "BEGIN IMMEDIATE")
    do {
      if found == 0 { try execute(on: database, sql: schemaV1) }
      if found < 2 { try execute(on: database, sql: """
        CREATE TABLE content_matching_jobs (
          id TEXT PRIMARY KEY,
          take_id TEXT NOT NULL REFERENCES takes(id) ON DELETE CASCADE,
          payload BLOB NOT NULL,
          created_at REAL NOT NULL
        );
        CREATE INDEX content_matching_take ON content_matching_jobs(take_id, created_at);
        """)
      }
      if found < 3 { try execute(on: database, sql: """
        CREATE TABLE pronunciation_jobs (id TEXT PRIMARY KEY, take_id TEXT NOT NULL REFERENCES takes(id) ON DELETE CASCADE, payload BLOB NOT NULL, created_at REAL NOT NULL);
        CREATE INDEX pronunciation_take ON pronunciation_jobs(take_id, created_at);
        """)
      }
      if found < 4 { try execute(on: database, sql: """
        CREATE TABLE dictation_progress (
          revision_id TEXT PRIMARY KEY REFERENCES segment_revisions(id) ON DELETE CASCADE,
          lesson_id TEXT NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
          payload BLOB NOT NULL
        );
        CREATE INDEX dictation_lesson ON dictation_progress(lesson_id);
        """)
      }
      try execute(on: database, sql: "PRAGMA user_version = 4")
      try execute(on: database, sql: "COMMIT")
    } catch {
      try? execute(on: database, sql: "ROLLBACK")
      throw error
    }
  }

  private static func execute(on database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      let primary = result & 0xFF
      throw primary == SQLITE_CONSTRAINT
        ? ProductionDatabaseError.constraint(message)
        : ProductionDatabaseError.execute(message)
    }
  }

  private static func scalarInt(on database: OpaquePointer, sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw ProductionDatabaseError.execute(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw ProductionDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static let schemaV1 = """
    CREATE TABLE lessons (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL CHECK(length(provider) > 0),
      external_id TEXT NOT NULL CHECK(length(external_id) > 0),
      source_url TEXT,
      title TEXT NOT NULL CHECK(length(title) > 0),
      author TEXT,
      lifecycle TEXT NOT NULL CHECK(lifecycle IN ('preparing','ready','failed','deleting')),
      generation INTEGER NOT NULL DEFAULT 1 CHECK(generation >= 1),
      current_audio_asset_id TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      UNIQUE(provider, external_id),
      FOREIGN KEY(current_audio_asset_id) REFERENCES media_assets(id) ON DELETE RESTRICT
    );

    CREATE TABLE media_assets (
      id TEXT PRIMARY KEY,
      lesson_id TEXT NOT NULL REFERENCES lessons(id) ON DELETE RESTRICT,
      role TEXT NOT NULL CHECK(role IN ('source_audio','thumbnail','take_audio','caption','waveform')),
      relative_path TEXT NOT NULL UNIQUE CHECK(length(relative_path) > 0),
      checksum TEXT NOT NULL CHECK(length(checksum) > 0),
      format TEXT,
      sample_rate INTEGER CHECK(sample_rate IS NULL OR sample_rate > 0),
      frame_count INTEGER CHECK(frame_count IS NULL OR frame_count > 0),
      status TEXT NOT NULL CHECK(status IN ('writing','ready','recovery','missing','deleting')),
      created_at REAL NOT NULL
    );

    CREATE TABLE segments (
      id TEXT PRIMARY KEY,
      lesson_id TEXT NOT NULL REFERENCES lessons(id) ON DELETE RESTRICT,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      current_revision_id TEXT,
      lineage_json BLOB,
      UNIQUE(lesson_id, ordinal),
      FOREIGN KEY(current_revision_id) REFERENCES segment_revisions(id) ON DELETE RESTRICT
    );

    CREATE TABLE segment_revisions (
      id TEXT PRIMARY KEY,
      segment_id TEXT NOT NULL REFERENCES segments(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK(revision >= 1),
      text TEXT NOT NULL CHECK(length(text) > 0),
      content_key TEXT NOT NULL CHECK(length(content_key) > 0),
      reference_key TEXT NOT NULL CHECK(length(reference_key) > 0),
      audio_asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE RESTRICT,
      start_frame INTEGER NOT NULL CHECK(start_frame >= 0),
      end_frame INTEGER NOT NULL CHECK(end_frame > start_frame),
      tokens_schema_version INTEGER NOT NULL CHECK(tokens_schema_version >= 1),
      tokens_json BLOB NOT NULL,
      baseline_json BLOB NOT NULL,
      overrides_json BLOB,
      created_at REAL NOT NULL,
      UNIQUE(segment_id, revision)
    );

    CREATE TABLE annotations (
      id TEXT PRIMARY KEY,
      revision_id TEXT NOT NULL REFERENCES segment_revisions(id) ON DELETE RESTRICT,
      kind TEXT NOT NULL CHECK(kind IN ('translation','ipa')),
      lookup_key TEXT NOT NULL,
      source TEXT NOT NULL,
      schema_version INTEGER NOT NULL CHECK(schema_version >= 1),
      automatic_value BLOB,
      override_value BLOB,
      created_at REAL NOT NULL,
      UNIQUE(revision_id, kind, lookup_key)
    );

    CREATE TABLE practice_sessions (
      id TEXT PRIMARY KEY,
      lesson_id TEXT NOT NULL REFERENCES lessons(id) ON DELETE RESTRICT,
      started_at REAL NOT NULL,
      ended_at REAL,
      checkpoint_json BLOB
    );

    CREATE TABLE practice_rounds (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES practice_sessions(id) ON DELETE RESTRICT,
      segment_revision_id TEXT NOT NULL REFERENCES segment_revisions(id) ON DELETE RESTRICT,
      audio_asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE RESTRICT,
      scope TEXT NOT NULL CHECK(scope IN ('sentence','phrase')),
      target_schema_version INTEGER NOT NULL CHECK(target_schema_version >= 1),
      target_json BLOB NOT NULL,
      source_speed REAL NOT NULL CHECK(source_speed > 0),
      created_at REAL NOT NULL
    );

    CREATE TABLE takes (
      id TEXT PRIMARY KEY,
      round_id TEXT NOT NULL UNIQUE REFERENCES practice_rounds(id) ON DELETE RESTRICT,
      media_asset_id TEXT REFERENCES media_assets(id) ON DELETE RESTRICT,
      outcome TEXT NOT NULL CHECK(outcome IN ('complete','no_speech','quiet','early_stop','interrupted','save_failed')),
      duration_frames INTEGER CHECK(duration_frames IS NULL OR duration_frames >= 0),
      status TEXT NOT NULL CHECK(status IN ('writing','finalizing','ready','recovery','discarded')),
      created_at REAL NOT NULL,
      committed_at REAL
    );

    CREATE TABLE engine_releases (
      id TEXT PRIMARY KEY,
      engine_key TEXT NOT NULL,
      version TEXT NOT NULL,
      model_checksum TEXT,
      capability_json BLOB NOT NULL,
      created_at REAL NOT NULL,
      UNIQUE(engine_key, version, model_checksum)
    );

    CREATE TABLE engine_installations (
      engine_release_id TEXT PRIMARY KEY REFERENCES engine_releases(id) ON DELETE RESTRICT,
      status TEXT NOT NULL CHECK(status IN ('unavailable','not_installed','downloading','verifying','installed','failed','removing')),
      relative_path TEXT,
      installed_at REAL,
      last_error_json BLOB
    );

    CREATE TABLE assessments (
      id TEXT PRIMARY KEY,
      take_id TEXT NOT NULL REFERENCES takes(id) ON DELETE RESTRICT,
      engine_release_id TEXT NOT NULL REFERENCES engine_releases(id) ON DELETE RESTRICT,
      profile_key TEXT NOT NULL,
      result_schema_version INTEGER NOT NULL CHECK(result_schema_version >= 1),
      status TEXT NOT NULL CHECK(status IN ('queued','running','complete','failed','cancelled','unsupported')),
      overall_score REAL,
      result_json BLOB,
      error_json BLOB,
      created_at REAL NOT NULL,
      completed_at REAL
    );

    CREATE TABLE jobs (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE,
      expected_generation INTEGER,
      input_schema_version INTEGER NOT NULL CHECK(input_schema_version >= 1),
      input_json BLOB NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed','cancelled')),
      checkpoint_json BLOB,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );

    CREATE TABLE job_attempts (
      id TEXT PRIMARY KEY,
      job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
      attempt INTEGER NOT NULL CHECK(attempt >= 1),
      run_token TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL CHECK(status IN ('running','succeeded','failed','cancelled')),
      started_at REAL NOT NULL,
      finished_at REAL,
      error_json BLOB,
      UNIQUE(job_id, attempt)
    );

    CREATE INDEX media_assets_lesson_role ON media_assets(lesson_id, role, status);
    CREATE INDEX segments_lesson_ordinal ON segments(lesson_id, ordinal);
    CREATE INDEX revisions_segment_created ON segment_revisions(segment_id, created_at);
    CREATE INDEX sessions_lesson_started ON practice_sessions(lesson_id, started_at);
    CREATE INDEX assessments_take_profile ON assessments(take_id, profile_key, created_at);
    CREATE INDEX jobs_status_created ON jobs(status, created_at);
    """
}


extension ProductionDatabase {
  /// Review resolves the round snapshot, even after a new timing revision is published.
  func savedTakeSentences(lessonID: UUID, paths: BackendPaths) throws -> [UUID: ProductionPreparedSentence] {
    let statement = try prepare("""
      SELECT t.id, p.target_json, r.revision, r.tokens_json, r.baseline_json, a.relative_path
      FROM takes t JOIN practice_rounds p ON p.id = t.round_id
      JOIN practice_sessions s ON s.id = p.session_id
      JOIN segment_revisions r ON r.id = p.segment_revision_id
      JOIN media_assets a ON a.id = p.audio_asset_id
      WHERE s.lesson_id = ? AND t.status = 'ready'
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID.uuidString, to: 1, in: statement)
    var result: [UUID: ProductionPreparedSentence] = [:]
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let idString = columnText(statement, 0),
        let id = UUID(uuidString: idString), let snapshotData = columnData(statement, 1),
        let tokensData = columnData(statement, 3), let baselineData = columnData(statement, 4),
        let path = columnText(statement, 5), let url = Self.safeManagedURL(path, under: paths.root)
      else { throw ProductionDatabaseError.execute("The saved take target is invalid.") }
      let snapshot = try JSONDecoder().decode(ProductionPracticeTargetSnapshot.self, from: snapshotData)
      let target = ProductionPracticeTarget(lessonID: snapshot.lessonID,
        lessonGeneration: snapshot.lessonGeneration, segmentID: snapshot.segmentID,
        segmentRevisionID: snapshot.segmentRevisionID, audioAssetID: snapshot.audioAssetID,
        audioURL: url, sampleRate: snapshot.sampleRate, startFrame: snapshot.startFrame,
        endFrame: snapshot.endFrame, text: snapshot.text, scope: snapshot.scope,
        wordIDs: snapshot.wordIDs, sourcePlaybackEndFrame: snapshot.sourcePlaybackEndFrame)
      try target.validate()
      result[id] = ProductionPreparedSentence(target: target,
        revision: Int(sqlite3_column_int64(statement, 2)),
        tokens: try JSONDecoder().decode([TranscriptWordToken].self, from: tokensData),
        baseline: try JSONDecoder().decode(CaptionBaseline.self, from: baselineData),
        annotations: try annotations(revisionID: target.segmentRevisionID))
    }
    return result
  }

  func contentMatchingJobs(lessonID: UUID? = nil) throws -> [ContentMatchingJob] {
    let statement = try prepare("""
      SELECT j.payload FROM content_matching_jobs j
      JOIN takes t ON t.id = j.take_id
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN practice_sessions s ON s.id = r.session_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE l.lifecycle = 'ready' AND (? IS NULL OR s.lesson_id = ?)
      ORDER BY j.created_at, j.id
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID?.uuidString, to: 1, in: statement)
    bind(lessonID?.uuidString, to: 2, in: statement)
    var jobs: [ContentMatchingJob] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let data = columnData(statement, 0) else {
        throw databaseError(for: status)
      }
      jobs.append(try JSONDecoder().decode(ContentMatchingJob.self, from: data))
    }
    return jobs
  }

  func enqueueContentMatching(
    takeID: UUID, selection: TranscriptionSelection, locale: String,
    provenance: TranscriptionProvenance, force: Bool = false
  ) throws -> ContentMatchingJob {
    let existing = try contentMatchingJobs().filter { $0.takeID == takeID }
    if let pending = existing.last(where: { $0.isPending }) { return pending }
    if !force, let last = existing.last { return last }
    let statement = try prepare("""
      SELECT r.target_json, a.checksum FROM takes t
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN practice_sessions s ON s.id = r.session_id
      JOIN lessons l ON l.id = s.lesson_id
      JOIN media_assets a ON a.id = t.media_asset_id
      WHERE t.id = ? AND t.status = 'ready' AND t.outcome IN ('complete','early_stop')
        AND l.lifecycle = 'ready' AND a.status = 'ready'
      """)
    defer { sqlite3_finalize(statement) }
    bind(takeID.uuidString, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      let targetData = columnData(statement, 0), let checksum = columnText(statement, 1)
    else { throw ProductionDatabaseError.constraint("This take is not available for content matching.") }
    let target = try JSONDecoder().decode(ProductionPracticeTargetSnapshot.self, from: targetData)
    let job = ContentMatchingJob(id: UUID(), takeID: takeID, target: target,
      selection: selection, locale: locale, provenance: provenance, audioChecksum: checksum,
      createdAt: Date(), policy: "asr-word-edit-v1", status: .queued)
    let insert = try prepare("INSERT INTO content_matching_jobs (id, take_id, payload, created_at) VALUES (?, ?, ?, ?)")
    defer { sqlite3_finalize(insert) }
    bind(job.id.uuidString, to: 1, in: insert)
    bind(takeID.uuidString, to: 2, in: insert)
    bind(try JSONEncoder().encode(job), to: 3, in: insert)
    sqlite3_bind_double(insert, 4, job.createdAt.timeIntervalSince1970)
    try stepDone(insert)
    return job
  }

  func updateContentMatching(_ job: ContentMatchingJob) throws {
    guard let previous = try contentMatchingJobs().first(where: { $0.id == job.id }),
      previous.isPending, previous.takeID == job.takeID,
      previous.target == job.target, previous.selection == job.selection,
      previous.provenance == job.provenance, previous.audioChecksum == job.audioChecksum,
      previous.locale == job.locale, previous.policy == job.policy
    else { throw ProductionDatabaseError.constraint("The matching job was removed or already completed.") }
    let update = try prepare("UPDATE content_matching_jobs SET payload = ? WHERE id = ?")
    defer { sqlite3_finalize(update) }
    bind(try JSONEncoder().encode(job), to: 1, in: update)
    bind(job.id.uuidString, to: 2, in: update)
    try stepDone(update)
  }
}

extension ProductionDatabase {
  func pronunciationJobs(lessonID: UUID? = nil) throws -> [PronunciationJob] {
    let statement = try prepare("""
      SELECT j.payload FROM pronunciation_jobs j
      JOIN takes t ON t.id = j.take_id
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN practice_sessions s ON s.id = r.session_id
      JOIN lessons l ON l.id = s.lesson_id
      WHERE l.lifecycle = 'ready' AND (? IS NULL OR s.lesson_id = ?)
      ORDER BY j.created_at, j.id
      """)
    defer { sqlite3_finalize(statement) }
    bind(lessonID?.uuidString, to: 1, in: statement)
    bind(lessonID?.uuidString, to: 2, in: statement)
    var jobs: [PronunciationJob] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let data = columnData(statement, 0) else {
        throw databaseError(for: status)
      }
      jobs.append(try JSONDecoder().decode(PronunciationJob.self, from: data))
    }
    return jobs
  }

  func enqueuePronunciation(
    takeID: UUID, words: [PronunciationWordTarget], accent: ReferenceAccent,
    provenance: String, force: Bool = false
  ) throws -> PronunciationJob {
    let existing = try pronunciationJobs().filter { $0.takeID == takeID }
    if let pending = existing.last(where: { $0.isPending }) { return pending }
    if !force, let last = existing.last { return last }
    let statement = try prepare("""
      SELECT r.target_json, a.checksum, source.checksum FROM takes t
      JOIN practice_rounds r ON r.id = t.round_id
      JOIN practice_sessions s ON s.id = r.session_id
      JOIN lessons l ON l.id = s.lesson_id
      JOIN media_assets a ON a.id = t.media_asset_id
      JOIN media_assets source ON source.id = r.audio_asset_id
      WHERE t.id = ? AND t.status = 'ready' AND t.outcome IN ('complete','early_stop')
        AND l.lifecycle = 'ready' AND a.status = 'ready'
      """)
    defer { sqlite3_finalize(statement) }
    bind(takeID.uuidString, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      let targetData = columnData(statement, 0), let checksum = columnText(statement, 1)
    else { throw ProductionDatabaseError.constraint("This take is not available for pronunciation assessment.") }
    let target = try JSONDecoder().decode(ProductionPracticeTargetSnapshot.self, from: targetData)
    let job = PronunciationJob(id: UUID(), takeID: takeID, target: target,
      words: words, accent: accent, provenance: provenance, sourceAudioChecksum: columnText(statement, 2), audioChecksum: checksum,
      createdAt: Date(), status: .queued)
    let insert = try prepare("INSERT INTO pronunciation_jobs (id, take_id, payload, created_at) VALUES (?, ?, ?, ?)")
    defer { sqlite3_finalize(insert) }
    bind(job.id.uuidString, to: 1, in: insert)
    bind(takeID.uuidString, to: 2, in: insert)
    bind(try JSONEncoder().encode(job), to: 3, in: insert)
    sqlite3_bind_double(insert, 4, job.createdAt.timeIntervalSince1970)
    try stepDone(insert)
    return job
  }

  func updatePronunciation(_ job: PronunciationJob) throws {
    guard let previous = try pronunciationJobs().first(where: { $0.id == job.id }),
      previous.isPending, previous.takeID == job.takeID,
      previous.target == job.target, previous.words == job.words,
      previous.provenance == job.provenance, previous.audioChecksum == job.audioChecksum,
      previous.sourceAudioChecksum == job.sourceAudioChecksum,
      previous.accent == job.accent, previous.createdAt == job.createdAt
    else { throw ProductionDatabaseError.constraint("The pronunciation job was removed or already completed.") }
    let update = try prepare("UPDATE pronunciation_jobs SET payload = ? WHERE id = ?")
    defer { sqlite3_finalize(update) }
    bind(try JSONEncoder().encode(job), to: 1, in: update)
    bind(job.id.uuidString, to: 2, in: update)
    try stepDone(update)
  }
}
