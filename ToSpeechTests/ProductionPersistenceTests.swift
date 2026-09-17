import AVFAudio
import CryptoKit
import Foundation
import JavaScriptCore
import SQLite3
import Testing

@testable import ToSpeech

@Suite(.serialized)
struct ProductionPersistenceTests {
  @Test func backendPathsCreateOnlyTheDeclaredProductionLayout() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()

    for directory in [
      paths.root, paths.sourceAudio, paths.thumbnails, paths.takeStaging,
      paths.finalTakes, paths.deletingTakes, paths.packages, paths.cache,
    ] {
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)
    }
    #expect(!FileManager.default.fileExists(atPath: paths.database.path))
  }

  @Test func schemaMigrationIsIdempotentAndEnforcesForeignKeys() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tospeech.sqlite3")

    var database: ProductionDatabase? = try ProductionDatabase(url: url)
    #expect(try await database?.schemaVersion() == ProductionDatabase.currentSchemaVersion)
    #expect(try await database?.foreignKeysEnabled() == true)
    #expect(try await database?.integrityCheck() == "ok")
    database = nil

    let reopened = try ProductionDatabase(url: url)
    #expect(try await reopened.schemaVersion() == ProductionDatabase.currentSchemaVersion)
    #expect(try await reopened.lessonCount() == 0)
  }

  @Test func newerSchemaIsPreservedAndRejected() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("tospeech.sqlite3")
    var raw: OpaquePointer?
    #expect(
      sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let futureVersion = ProductionDatabase.currentSchemaVersion + 1
    #expect(sqlite3_exec(raw, "PRAGMA user_version = \(futureVersion)", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(raw)

    do {
      _ = try ProductionDatabase(url: url)
      Issue.record("A newer database must not be opened or reset")
    } catch let error as ProductionDatabaseError {
      #expect(
        error
          == .unsupportedSchema(
            found: futureVersion, supported: ProductionDatabase.currentSchemaVersion))
    }

    #expect(sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(Int(sqlite3_column_int(statement, 0)) == futureVersion)
    sqlite3_finalize(statement)
    sqlite3_close_v2(raw)
  }

  @Test func lessonIdentityPersistsAndDuplicateImportIsRejected() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tospeech.sqlite3")
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let input = NewLesson(
      id: id,
      provider: "youtube",
      externalID: "dQw4w9WgXcQ",
      sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
      title: "Pronunciation lesson",
      author: "Teacher",
      createdAt: date)

    var database: ProductionDatabase? = try ProductionDatabase(url: url)
    let inserted = try await database!.insertLesson(input)
    #expect(inserted.id == id)
    #expect(inserted.lifecycle == .preparing)
    #expect(inserted.generation == 1)
    #expect(try await database!.lessonCount() == 1)

    do {
      _ = try await database!.insertLesson(
        NewLesson(provider: "youtube", externalID: input.externalID, title: "Duplicate"))
      Issue.record("Duplicate provider/external identity should be rejected")
    } catch let error as ProductionDatabaseError {
      guard case .constraint = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }

    database = nil
    let reopened = try ProductionDatabase(url: url)
    #expect(try await reopened.lesson(id: id) == inserted)
  }

  @MainActor @Test func mutedVideoFollowerAcceptsOnlyAValidatedYouTubeSourceAndPausesForCapture()
    throws
  {
    let source = try #require(
      YouTubeVisualSource(
        provider: "youtube", externalID: "dQw4w9WgXcQ",
        sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")))
    #expect(
      YouTubeVisualSource(
        provider: "youtube", externalID: "dQw4w9WgXcQ",
        sourceURL: URL(string: "https://youtube.com.evil.invalid/watch?v=dQw4w9WgXcQ")) == nil)

    let follower = YouTubeVideoFollower()
    follower.configure(source: source)
    #expect(follower.state == .loading)
    follower.receive(event: "ready")
    follower.follow(sourceSeconds: 4.2, isNativeAudioPlaying: true)
    #expect(follower.state == .following)
    follower.follow(sourceSeconds: 4.2, isNativeAudioPlaying: false)
    #expect(follower.state == .paused)
    follower.receive(event: "error", code: 150)
    #expect(follower.state == .unavailable)
    #expect(follower.lastErrorCode == 150)
    let failedPage = follower.pageID
    follower.retry()
    #expect(follower.state == .loading)
    #expect(follower.pageID != failedPage)
    #expect(follower.lastErrorCode == nil)
    #expect(YouTubeVideoFollowerView.applicationOrigin.scheme == "https")
    #expect(YouTubeVideoFollowerView.applicationOrigin.host == "com.unknownstudio.tospeech")
  }

  @MainActor @Test func youtubeTransportWaitsForPlayerReadyAndKeepsTheLatestIntent() throws {
    for pauseBeforeReady in [false, true] {
      let context = try #require(JSContext())
      context.evaluateScript("""
        var calls=[], notices=[], options, fakePlayer, isReady=false;
        var window={location:{origin:'https://com.unknownstudio.tospeech'},webkit:{messageHandlers:{
          toSpeechYouTube:{postMessage:function(message){notices.push(message.event);}}
        }}};
        function record(value) { if(!isReady) throw new Error('Player used before ready'); calls.push(value); }
        var YT={Player:function(id, config){
          options=config;
          fakePlayer={
            mute:function(){record('mute');}, setVolume:function(v){record('volume:'+v);},
            seekTo:function(s){record('seek:'+s);}, playVideo:function(){record('play');},
            pauseVideo:function(){record('pause');}, cueVideoById:function(){record('cue');}
          };
          return fakePlayer;
        }};
        """)
      context.evaluateScript(YouTubeVideoFollowerView.playerScript)
      context.evaluateScript("""
        window.ToSpeechVideo.dispatch({action:'cue',videoID:'Ahc8WG5FXCs',seconds:0});
        window.ToSpeechVideo.dispatch({action:'follow',seconds:4});
        onYouTubeIframeAPIReady();
        window.ToSpeechVideo.dispatch({action:'follow',seconds:12});
        """)
      #expect(context.exception == nil)
      #expect(context.evaluateScript("calls.length")?.toInt32() == 0)
      if pauseBeforeReady {
        context.evaluateScript("window.ToSpeechVideo.dispatch({action:'pause'});")
      }
      context.evaluateScript("isReady=true;options.events.onReady({target:fakePlayer});")
      #expect(context.exception == nil)
      let actions = try #require(context.evaluateScript("calls.join('|')")?.toString())
      #expect(actions.contains("mute|volume:0"))
      if pauseBeforeReady {
        #expect(actions.hasSuffix("pause"))
        #expect(!actions.contains("play"))
      } else {
        #expect(actions.hasSuffix("seek:12|play"))
        #expect(!actions.contains("seek:4"))
      }
    }
  }

  @Test func deletionFenceAdvancesGenerationAndRejectsStaleCallbacks() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductionDatabase(url: root.appendingPathComponent("tospeech.sqlite3"))
    let input = NewLesson(provider: "youtube", externalID: "abcdefghijk", title: "Lesson")
    let inserted = try await database.insertLesson(input)

    let nextGeneration = try await database.markLessonDeleting(
      id: inserted.id, expectedGeneration: inserted.generation)
    #expect(nextGeneration == 2)
    let deleting = try await database.lesson(id: inserted.id)
    #expect(deleting.lifecycle == .deleting)
    #expect(deleting.generation == 2)

    do {
      _ = try await database.markLessonDeleting(id: inserted.id, expectedGeneration: 1)
      Issue.record("A stale callback should not pass the generation fence")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: 1))
    }
  }

  @Test func deletingB1LessonRemovesItsMetadataOnlyAfterGenerationFence() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductionDatabase(url: root.appendingPathComponent("tospeech.sqlite3"))
    let inserted = try await database.insertLesson(
      NewLesson(provider: "local", externalID: UUID().uuidString, title: "Local audio"))

    let deletionGeneration = try await database.markLessonDeleting(
      id: inserted.id, expectedGeneration: inserted.generation)
    #expect(try await database.assetsForLessonDeletion(lessonID: inserted.id).isEmpty)
    try await database.completeLessonDeletion(
      lessonID: inserted.id, expectedGeneration: deletionGeneration)
    #expect(try await database.lessonCount() == 0)
  }

  @Test func failedImportRetainsInputAndRetryUsesANewAttemptToken() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductionDatabase(url: root.appendingPathComponent("tospeech.sqlite3"))
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "abcdefghijk", title: "Lesson"))
    let jobID = UUID()
    let firstToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: firstToken,
      inputJSON: "{\"lessonID\":\"\(lesson.id.uuidString)\"}",
      checkpointJSON: "{\"phase\":\"resolving\"}")
    try await database.checkpointImportJob(
      id: jobID, expectedGeneration: lesson.generation, runToken: firstToken, status: "failed",
      checkpointJSON: "{\"phase\":\"failed\"}")
    let failedAttempt = try await database.importAttempts(jobID: jobID)
    #expect(failedAttempt.count == 1)
    #expect(failedAttempt[0].status == "failed")
    #expect(failedAttempt[0].finishedAt != nil)
    #expect(try await database.unfinishedImportJobs().first?.runToken == firstToken)

    let retryToken = try await database.beginImportRetry(
      id: jobID, expectedGeneration: lesson.generation)
    let restarted = try await database.unfinishedImportJobs().first
    let attempts = try await database.importAttempts(jobID: jobID)
    #expect(retryToken != firstToken)
    #expect(restarted?.status == "running")
    #expect(restarted?.runToken == retryToken)
    #expect(attempts.map(\.status) == ["failed", "running"])

    do {
      try await database.checkpointImportJob(
        id: jobID, expectedGeneration: lesson.generation, runToken: firstToken,
        status: "cancelled", checkpointJSON: "{\"phase\":\"cancelled\"}")
      Issue.record("A stale attempt must not overwrite the retry")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: lesson.generation))
    }
    #expect(try await database.unfinishedImportJobs().first?.status == "running")
  }
  @Test func retryRevokesAnAttemptThatWasStillRunning() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try ProductionDatabase(url: root.appendingPathComponent("tospeech.sqlite3"))
    let lesson = try await db.insertLesson(NewLesson(provider: "youtube", externalID: "abcdefghijk", title: "Retry race"))
    let jobID = UUID(), oldToken = UUID()
    try await db.persistImportJob(id: jobID, lessonID: lesson.id, expectedGeneration: 1, runToken: oldToken,
      inputJSON: "{\"lessonID\":\"\(lesson.id.uuidString)\"}", checkpointJSON: "{\"phase\":\"cancelled\",\"detail\":\"old error\"}")
    let newToken = try await db.beginImportRetry(id: jobID, expectedGeneration: 1)
    #expect(try await db.importAttempts(jobID: jobID).map(\.status) == ["cancelled", "running"])
    let stored = try #require(try await db.unfinishedImportJobs().first)
    let checkpoint = try #require(try JSONSerialization.jsonObject(with: Data(stored.checkpointJSON.utf8)) as? [String: Any])
    #expect(checkpoint["phase"] as? String == "resolving")
    #expect(checkpoint["detail"] is NSNull)
    do {
      try await db.checkpointImportJob(id: jobID, expectedGeneration: 1, runToken: oldToken, status: "cancelled", checkpointJSON: "{}")
      Issue.record("An old live attempt must not cancel the new attempt")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: 1))
    }
    #expect(try await db.unfinishedImportJobs().first?.runToken == newToken)
    #expect(try await db.unfinishedImportJobs().first?.status == "running")
  }

  @Test func deleteFenceRejectsInFlightImportCheckpoint() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductionDatabase(url: root.appendingPathComponent("tospeech.sqlite3"))
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "delete12345", title: "Deleting"))
    let jobID = UUID()
    let token = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: token,
      inputJSON: "{\"lessonID\":\"\(lesson.id.uuidString)\"}",
      checkpointJSON: "{\"phase\":\"downloadingAudio\"}")
    _ = try await database.markLessonDeleting(
      id: lesson.id, expectedGeneration: lesson.generation)

    do {
      try await database.checkpointImportJob(
        id: jobID, expectedGeneration: lesson.generation, runToken: token, status: "running",
        checkpointJSON: "{\"phase\":\"probing\"}")
      Issue.record("A deleting lesson accepted a stale import checkpoint")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: lesson.generation))
    }
  }

  @Test func readyPublicationPersistsMetadataDurationAndAttemptAtomically() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let lessonID = UUID()
    let jobID = UUID()
    let token = UUID()
    var database: ProductionDatabase? = try ProductionDatabase(url: paths.database)
    _ = try await database!.insertLesson(
      NewLesson(id: lessonID, provider: "youtube", externalID: "ready123456", title: "Pending"))
    try await database!.persistImportJob(
      id: jobID, lessonID: lessonID, expectedGeneration: 1, runToken: token,
      inputJSON: "{\"lessonID\":\"\(lessonID.uuidString)\"}",
      checkpointJSON: "{\"phase\":\"publishing\"}")
    let audio = MediaAsset(
      id: UUID(), lessonID: lessonID, role: .sourceAudio,
      relativePath: "Media/SourceAudio/audio.m4a", checksum: "abc", format: "m4a",
      sampleRate: 48_000, frameCount: 144_000, createdAt: Date())
    try await database!.publishImportedAssets(
      lessonID: lessonID, expectedGeneration: 1, jobID: jobID, runToken: token,
      title: "Published title", author: "Teacher", assets: [audio],
      checkpointJSON: "{\"phase\":\"ready\"}")
    #expect(try await database!.lesson(id: lessonID).lifecycle == .ready)
    #expect(try await database!.importAttempts(jobID: jobID).map(\.status) == ["succeeded"])
    database = nil

    let reopened = try ProductionDatabase(url: paths.database)
    let summary = try await reopened.librarySummaries(paths: paths).first
    #expect(summary?.title == "Published title")
    #expect(summary?.author == "Teacher")
    #expect(summary?.duration == 3)
  }

  @MainActor @Test func watchedImportPresentationTransitionsToReadyWithoutLosingSheetIdentity()
    async throws
  {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(
        provider: "youtube", externalID: "stable12345",
        sourceURL: URL(string: "https://www.youtube.com/watch?v=stable12345"),
        title: "Stable progress"))
    let jobID = UUID()
    let runToken = UUID()
    let startedAt = Date()
    let input = try JSONSerialization.data(withJSONObject: [
      "kind": "youtube",
      "provider": "youtube",
      "externalID": "stable12345",
      "sourceURL": "https://www.youtube.com/watch?v=stable12345",
      "title": "Stable progress",
      "lessonID": lesson.id.uuidString,
    ])
    let progressCheckpoint = ImportCheckpoint(
      phase: .preparingTranscript, workspaceRelativePath: "Cache/ImportJobs/\(jobID.uuidString)",
      manifestRelativePath: nil, detail: nil, updatedAt: startedAt)
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation,
      runToken: runToken, inputJSON: String(decoding: input, as: UTF8.self),
      checkpointJSON: String(
        decoding: try JSONEncoder().encode(progressCheckpoint), as: UTF8.self))

    let service = ProductionImportService(
      database: database, paths: paths, usesSpeechFallback: false)
    let model = ProductionLibraryModel(service: service)
    await model.load()
    let job = try #require(model.jobs.first)
    model.showImportStatus(for: job)
    let progressContext = try #require(model.importPresentation)
    guard case .progress = progressContext.presentation else {
      Issue.record("The watched import did not present progress")
      return
    }

    let asset = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/stable.m4a", checksum: "stable", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: startedAt)
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Stable progress")],
      source: .creatorCaption, sampleRate: 48_000, frameCount: 96_000)
    let readyCheckpoint = ImportCheckpoint(
      phase: .ready, workspaceRelativePath: "Cache/ImportJobs/\(jobID.uuidString)",
      manifestRelativePath: nil, detail: nil, updatedAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID,
      runToken: runToken, title: "Stable progress", author: nil, assets: [asset],
      segments: segments,
      checkpointJSON: String(
        decoding: try JSONEncoder().encode(readyCheckpoint), as: UTF8.self))

    await model.load(showLoadingIndicator: false)
    let readyContext = try #require(model.importPresentation)
    #expect(readyContext.id == progressContext.id)
    #expect(model.jobs.isEmpty)
    guard case .ready = readyContext.presentation else {
      Issue.record("The watched import disappeared instead of transitioning to ready")
      return
    }
  }

  @Test func vttPreparationPersistsFrameTimedImmutableRevisionsWithoutInventingWordTimes()
    async throws
  {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "caption1234", title: "Caption lesson"))
    let jobID = UUID()
    let token = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: token,
      inputJSON: "{\"lessonID\":\"\(lesson.id.uuidString)\"}",
      checkpointJSON: "{\"phase\":\"preparingTranscript\"}")

    let cues = try WebVTTCaptionParser.parse(
      """
      WEBVTT

      00:00:01.250 --> 00:00:03.500 align:start
      <c>Small changes, big difference.</c>

      """)
    let segments = try CaptionTranscriptBuilder.build(
      cues: cues, source: .creatorCaption, sampleRate: 48_000, frameCount: 240_000)
    let tokens = try JSONDecoder().decode(
      [TranscriptWordToken].self, from: Data(try #require(segments.first).tokensJSON.utf8))
    #expect(
      tokens.allSatisfy { $0.startFrame == nil && $0.endFrame == nil && $0.needsTimingReview })

    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/caption.m4a", checksum: "caption-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 240_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: token,
      title: "Caption lesson", author: "Teacher", assets: [audio], segments: segments,
      checkpointJSON: "{\"phase\":\"ready\"}")

    let target = try #require(try await database.practiceTarget(lessonID: lesson.id, paths: paths))
    #expect(target.text == "Small changes, big difference.")
    #expect(target.startFrame == 60_000)
    #expect(target.endFrame == 168_000)
    #expect(try await database.lesson(id: lesson.id).lifecycle == .ready)
  }

  @Test func appleSpeechWordTimesRemainFrameAccurateWhenTheRecognizerSuppliesThem() throws {
    let segments = try CaptionTranscriptBuilder.build(
      cues: [
        CaptionCue(
          start: 2, end: 3.5, text: "Small changes.",
          words: [
            CaptionWord(text: "Small", start: 2, end: 2.4),
            CaptionWord(text: "changes", start: 2.45, end: 3.1),
          ])
      ],
      source: .appleSpeech, sampleRate: 48_000, frameCount: 240_000)
    let words = try JSONDecoder().decode(
      [TranscriptWordToken].self, from: Data(try #require(segments.first).tokensJSON.utf8))
    #expect(words.map(\.startFrame) == [96_000, 117_600])
    #expect(words.map(\.endFrame) == [115_200, 148_800])
    #expect(words.allSatisfy { !$0.needsTimingReview })
  }

  @Test func captionWordsUseOnlyObservedSpeechRangesInTranscriptOrder() throws {
    let speech = [
      CaptionCue(
        start: 1, end: 4, text: "I never thought it would make such a difference",
        words: [
          CaptionWord(text: "I", start: 1, end: 1.1),
          CaptionWord(text: "never", start: 1.15, end: 1.5),
          CaptionWord(text: "thought", start: 1.55, end: 1.9),
          CaptionWord(text: "it", start: 1.95, end: 2.05),
          CaptionWord(text: "would", start: 2.1, end: 2.35),
          CaptionWord(text: "make", start: 2.4, end: 2.75),
          CaptionWord(text: "such", start: 2.8, end: 3.05),
          CaptionWord(text: "a", start: 3.1, end: 3.18),
          CaptionWord(text: "difference", start: 3.2, end: 3.8),
        ])
    ]
    let enriched = CaptionWordTimingAligner.enriching(
      captionCues: [
        CaptionCue(start: 1, end: 4, text: "I never thought it would make such a difference.")
      ], with: speech)
    let words = try #require(enriched.first?.words)
    #expect(
      words.map(\.text) == [
        "I", "never", "thought", "it", "would", "make", "such", "a", "difference.",
      ])
    #expect(words[5].start == 2.4)
    #expect(words[5].end == 2.75)

    let partial = CaptionWordTimingAligner.alignedWords(
      for: ["known", "missing"], cueStart: 0, cueEnd: 2,
      speechCues: [
        CaptionCue(
          start: 0, end: 2, text: "known",
          words: [CaptionWord(text: "known", start: 0.2, end: 0.7)])
      ])
    #expect(partial[0]?.start == 0.2)
    #expect(partial[1] == nil)
  }

  @Test func importFailurePresentationNeverLeaksHelperDiagnostics() {
    let failure = ProductionImportError.subprocess(
      .unsuccessful(
        exitStatus: 1,
        diagnostics: "WARNING [youtube] HTTP Error 429: Too Many Requests --cookies-from-browser"))
    #expect(failure.presentationDescription.contains("temporarily limiting downloads"))
    #expect(!failure.presentationDescription.contains("HTTP Error"))
    #expect(!failure.presentationDescription.contains("cookies"))
  }

  @Test func bundledOfflineIPADictionaryKeepsUSAndUKSourcesSeparate() async throws {
    let dictionary = try OfflineIPADictionary.bundled()
    let us = try await dictionary.pronunciations(for: "small", accent: .us)
    let uk = try await dictionary.pronunciations(for: "small", accent: .uk)
    #expect(us.first?.ipa == "ˈsmɔɫ")
    #expect(us.first?.source == "ipa-dict")
    #expect(uk.first?.ipa == "smˈɔːl")
    #expect(uk.first?.source == "britfone")
    #expect(try await dictionary.pronunciations(for: "not-a-real-word", accent: .uk).isEmpty)
  }

  @Test func ipaAnnotationBuilderUsesTheFallbackOnlyForWordsTheDictionaryLacks() async throws {
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Small zxqvitron 42")], source: .creatorCaption,
      sampleRate: 48_000, frameCount: 96_000)
    let dictionary = try OfflineIPADictionary.bundled()
    let annotations = try await IPAAnnotationBuilder.build(segments: segments, dictionary: dictionary) { word, accent in
      OfflineIPAPronunciation(ipa: "\(word):\(accent.rawValue)", source: "fake-g2p", sourceRevision: "0")
    }
    func annotation(_ key: String) -> PreparedLessonAnnotation? { annotations.first { $0.lookupKey == key } }
    #expect(annotation("caption-0-word-0:uk")?.source == "britfone")
    #expect(annotation("caption-0-word-0:us")?.source == "ipa-dict")
    let generated = try #require(annotation("caption-0-word-1:uk"))
    #expect(generated.source == "fake-g2p")
    let value = try JSONDecoder().decode(IPAAnnotationValue.self, from: generated.automaticValue)
    #expect(value.pronunciations.map(\.ipa) == ["zxqvitron:UK"])
    #expect(annotation("caption-0-word-1:us")?.source == "fake-g2p")
    // Digits-only tokens are not sent to the generator.
    #expect(annotation("caption-0-word-2:uk") == nil)
  }

  @Test func bundledUKPronunciationsParseWithUKInventory() async throws {
    let dictionary = try OfflineIPADictionary.bundled()
    let rows = try await dictionary.allPronunciations(accent: .uk)
    let unparseable = rows.filter { UKPhoneInventory.parse($0.ipa) == nil }
    #expect(rows.count > 16_000)
    #expect(unparseable.isEmpty, "\(unparseable.count) UK rows do not parse, e.g. \(unparseable.prefix(5))")
    // The Wiktionary layer only fills gaps: Britfone stays the first choice.
    let wiktionary = rows.filter { $0.source.hasPrefix("wiktionary") }
    #expect(wiktionary.count > 50_000)
    let britfoneKeys = Set(rows.filter { $0.source == "britfone" }.map(\.lookupKey))
    #expect(wiktionary.allSatisfy { !britfoneKeys.contains($0.lookupKey) })
  }

  @Test func captionAudioMismatchIsMarkedForReviewWithoutChangingCaptionTiming() throws {
    let captions = [CaptionCue(start: 12, end: 14, text: "Small changes, big difference.")]
    let matched = CaptionAudioMismatchDetector.markingReview(
      captionCues: captions,
      against: [CaptionCue(start: 12.1, end: 14.1, text: "Small changes, big difference.")])
    #expect(matched.first?.timingReviewReason == nil)

    let mismatched = CaptionAudioMismatchDetector.markingReview(
      captionCues: captions,
      against: [CaptionCue(start: 12.1, end: 14.1, text: "Please subscribe to the channel.")])
    #expect(mismatched.first?.timingReviewReason == "caption_audio_text_mismatch")
    #expect(mismatched.first?.start == 12)
    #expect(mismatched.first?.end == 14)

    let segments = try CaptionTranscriptBuilder.build(
      cues: mismatched, source: .creatorCaption, sampleRate: 48_000, frameCount: 960_000)
    let firstSegment = try #require(segments.first)
    let baselineObject = try JSONSerialization.jsonObject(
      with: Data(firstSegment.baselineJSON.utf8))
    let baseline = try #require(
      baselineObject as? [String: Any])
    #expect(baseline["sentenceTimingNeedsReview"] as? Bool == true)
    #expect(baseline["timingReviewReason"] as? String == "caption_audio_text_mismatch")
  }

  @Test func translationTargetsSkipSentencesAlreadyTranslatedIntoThatLanguage() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "translation-lesson", title: "Translation lesson"))
    let jobID = UUID()
    let token = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: token,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [
        CaptionCue(start: 0, end: 1, text: "Small changes"),
        CaptionCue(start: 1, end: 2, text: "add up quickly"),
      ], source: .creatorCaption, sampleRate: 48_000, frameCount: 96_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/translation.m4a", checksum: "translation-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: token,
      title: "Translation lesson", author: nil, assets: [audio], segments: segments,
      checkpointJSON: "{\"phase\":\"ready\"}")
    let vietnamese = TranslationLanguage.legacyDefault, japanese = TranslationLanguage(identifier: "ja")
    let all = try await database.preparationTargets(lessonID: lesson.id)
    #expect(all.count == 2)
    #expect(try await database.preparationTargets(lessonID: lesson.id, missingTranslation: vietnamese.lookupKey).count == 2)

    let first = try #require(all.first)
    let value = try JSONEncoder().encode(
      SentenceTranslationValue(text: "Những thay đổi nhỏ", sourceLanguage: "en", targetLanguage: "vi"))
    try await database.storeAutomaticAnnotation(
      revisionID: first.revisionID, kind: .translation, lookupKey: vietnamese.lookupKey,
      source: "apple-translation", value: value)
    let remaining = try await database.preparationTargets(lessonID: lesson.id, missingTranslation: vietnamese.lookupKey)
    #expect(remaining.map(\.revisionID) == all.dropFirst().map(\.revisionID))
    // Another native language still needs every sentence.
    #expect(try await database.preparationTargets(lessonID: lesson.id, missingTranslation: japanese.lookupKey).count == 2)

    // A manual translation counts as present too, and the prepared sentence reads per language.
    let second = try #require(all.last)
    try await database.storeAnnotationOverride(
      revisionID: second.revisionID, kind: .translation, lookupKey: japanese.lookupKey, source: "manual",
      value: try JSONEncoder().encode(
        SentenceTranslationValue(text: "すぐに積み重なる", sourceLanguage: "en", targetLanguage: "ja")))
    #expect(try await database.preparationTargets(lessonID: lesson.id, missingTranslation: japanese.lookupKey).count == 1)
    let prepared = try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths)
    #expect(prepared.first?.translation(in: vietnamese) == "Những thay đổi nhỏ")
    #expect(prepared.first?.translation(in: japanese) == nil)
    #expect(prepared.last?.translation(in: japanese) == "すぐに積み重なる")
    #expect(prepared.last?.translation == nil, "The default projection stays Vietnamese")
  }

  @Test func ipaPreparationCachesAutomaticValuesAndKeepsManualOverrides() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "ipa-lesson", title: "IPA lesson"))
    let jobID = UUID()
    let token = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: token,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Small changes")], source: .creatorCaption,
      sampleRate: 48_000, frameCount: 96_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/ipa.m4a", checksum: "ipa-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: token,
      title: "IPA lesson", author: nil, assets: [audio], segments: segments,
      checkpointJSON: "{\"phase\":\"ready\"}")

    let dictionary = try OfflineIPADictionary.bundled()
    try await IPAAnnotationPreparer(database: database, dictionary: dictionary).prepare(
      lessonID: lesson.id)
    let revisionID = try #require(
      try await database.preparationTargets(lessonID: lesson.id).first?.revisionID)
    let lookupKey = "caption-0-word-0:uk"
    let automatic = try #require(
      try await database.annotations(revisionID: revisionID).first(where: {
        $0.kind == .ipa && $0.lookupKey == lookupKey
      }))
    #expect(automatic.overrideValue == nil)
    let manual = Data("manual IPA".utf8)
    try await database.storeAnnotationOverride(
      revisionID: revisionID, kind: .ipa, lookupKey: lookupKey, source: "manual", value: manual)
    try await IPAAnnotationPreparer(database: database, dictionary: dictionary).prepare(
      lessonID: lesson.id)
    let afterRefresh = try #require(
      try await database.annotations(revisionID: revisionID).first(where: {
        $0.kind == .ipa && $0.lookupKey == lookupKey
      }))
    let initialValue = try JSONDecoder().decode(
      IPAAnnotationValue.self, from: try #require(automatic.automaticValue))
    let refreshedValue = try JSONDecoder().decode(
      IPAAnnotationValue.self, from: try #require(afterRefresh.automaticValue))
    #expect(refreshedValue == initialValue)
    #expect(afterRefresh.overrideValue == manual)
    let prepared = try #require(
      try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths).first)
    let projectedWord = try #require(prepared.lessonSentence(number: 1).words.first)
    #expect(projectedWord.ipaUK == initialValue.pronunciations.first?.ipa)
    let explicit = IPAAnnotationValue(accent: .uk, pronunciations: [
      .init(ipa: "smɔːl", source: "user", sourceRevision: "choice-1")
    ])
    try await database.storeAnnotationOverride(revisionID: revisionID, kind: .ipa,
      lookupKey: lookupKey, source: "user", value: JSONEncoder().encode(explicit))
    let edited = try #require(try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths).first)
    let editedToken = try #require(edited.tokens.first)
    #expect(edited.ipa(for: editedToken, accent: .uk) == "smɔːl")
    #expect(edited.ipaOverride(for: editedToken, accent: .uk)?.map(\.ipa) == ["smɔːl"])
    #expect(edited.ipaOverride(for: editedToken, accent: .uk)?.first?.source.contains("manual override") == true)
    #expect(edited.ipaOverride(for: editedToken, accent: .us) == nil)
  }

  @Test func publishingPreparedLessonPersistsSegmentAnnotations() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "annotated", title: "Annotated lesson"))
    let jobID = UUID()
    let runToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Hello world")], source: .parakeet,
      sampleRate: 48_000, frameCount: 96_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/annotated.m4a", checksum: "annotated-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: Date())
    let annotation = PreparedLessonAnnotation(
      segmentID: try #require(segments.first).id, kind: .ipa, lookupKey: "hello:us",
      source: "ipa-dict", automaticValue: Data("/həˈloʊ/".utf8))

    // Regression: the annotation INSERT previously left created_at unbound,
    // failing the NOT NULL constraint and aborting the whole import.
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: runToken,
      title: "Annotated lesson", author: nil, assets: [audio], segments: segments,
      annotations: [annotation], checkpointJSON: "{\"phase\":\"ready\"}")

    let sentences = try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths)
    let stored = try #require(sentences.first).annotations
    #expect(stored.count == 1)
    #expect(stored.first?.kind == .ipa)
    #expect(stored.first?.lookupKey == "hello:us")
    #expect(stored.first?.automaticValue == Data("/həˈloʊ/".utf8))
  }

  @Test func sentenceListeningMarginRespectsNeighboursAndAudioEnd() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "local", externalID: "tail-margin", title: "Sentence tails"))
    let jobID = UUID(), runToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [
        CaptionCue(start: 0, end: 1, text: "First."),
        CaptionCue(start: 1.1, end: 2, text: "Second."),
        CaptionCue(start: 3, end: 3.9, text: "Last."),
      ], source: .parakeet, sampleRate: 16_000, frameCount: 64_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/tails.caf", checksum: "fixture", format: "caf",
      sampleRate: 16_000, frameCount: 64_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: runToken,
      title: lesson.title, author: nil, assets: [audio], segments: segments, checkpointJSON: "{}")
    let targets = try await database.practiceTargets(lessonID: lesson.id, paths: paths)
    #expect(targets.map(\.endFrame) == [16_000, 32_000, 62_400])
    #expect(targets.map(\.playbackEndFrame) == [17_600, 36_000, 64_000])
    let sentences = try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths)
    #expect(sentences.map { $0.baseline.cueEndFrame } == [16_000, 32_000, 62_400])
    #expect(SentencePlaybackBoundary.endFrame(
      sentenceEnd: 16_000, sampleRate: 16_000, audioFrameCount: 64_000,
      nextSentenceStart: 15_000, hasTimingOverride: false) == 16_000)
    let snapshot = try #require(targets.first).snapshot
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(ProductionPracticeTargetSnapshot.self, from: encoded)
      .sourcePlaybackEndFrame == 17_600)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "sourcePlaybackEndFrame")
    let restored = try JSONDecoder().decode(ProductionPracticeTargetSnapshot.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.sourcePlaybackEndFrame == nil)
  }

  @MainActor @Test func removingAPhantomWordPublishesARevisionWithoutItsTextTokenOrIPA() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "phantom-lesson", title: "Phantom lesson"))
    let jobID = UUID(), runToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: "{}", checkpointJSON: "{}")
    let cue = CaptionCue(start: 0, end: 1, text: "fortune must must be.", words: [
      .init(text: "fortune", start: 0, end: 0.4), .init(text: "must", start: 0.4, end: 0.41),
      .init(text: "must", start: 0.41, end: 0.7), .init(text: "be.", start: 0.7, end: 1)])
    let segments = try CaptionTranscriptBuilder.build(
      cues: [cue], source: .parakeet, sampleRate: 48_000, frameCount: 96_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/phantom.m4a", checksum: "phantom-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: runToken,
      title: "Phantom lesson", author: nil, assets: [audio], segments: segments,
      checkpointJSON: "{\"phase\":\"ready\"}")
    let original = try #require(
      try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths).first)
    #expect(original.tokens.map(\.text) == ["fortune", "must", "must", "be."])
    let phantom = original.tokens[1], kept = original.tokens[2]
    for token in [phantom, kept] {
      try await database.storeAutomaticAnnotation(
        revisionID: original.id, kind: .ipa, lookupKey: "\(token.id):uk", source: "britfone", value: Data("mˈɐst".utf8))
    }
    try await database.storeAutomaticAnnotation(
      revisionID: original.id, kind: .translation, lookupKey: "sentence:vi", source: "auto", value: Data("x".utf8))

    let result = try await database.publishTranscriptRevision(
      segmentID: original.target.segmentID, expectedRevisionID: original.id, removingTokenID: phantom.id)
    let current = try #require(
      try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths).first)
    #expect(current.id == result.revisionID && current.revision == original.revision + 1)
    #expect(current.target.text == "fortune must be.")
    #expect(current.tokens == original.tokens.filter { $0.id != phantom.id })
    #expect(current.target.startFrame == original.target.startFrame && current.target.endFrame == original.target.endFrame)
    #expect(!current.hasManualTiming)
    let keys = current.annotations.map { "\($0.kind.rawValue)|\($0.lookupKey)" }.sorted()
    #expect(keys == ["ipa|\(kept.id):uk", "translation|sentence:vi"])

    do {
      _ = try await database.publishTranscriptRevision(
        segmentID: original.target.segmentID, expectedRevisionID: original.id, removingTokenID: kept.id)
      Issue.record("A stale editor must not remove a word from a superseded revision")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: 0))
    }
    #expect(ProductionDatabase.transcriptText("Hello world.", tokens: [
      .init(id: "a", text: "Hello", startFrame: nil, endFrame: nil, needsTimingReview: true),
      .init(id: "b", text: "world.", startFrame: nil, endFrame: nil, needsTimingReview: true)], removing: 0) == "world.")
  }

  @MainActor @Test func timingEditCreatesANewRevisionAndPreservesAnnotationProvenance() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "youtube", externalID: "timing-lesson", title: "Timing lesson"))
    let jobID = UUID()
    let runToken = UUID()
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: "{}", checkpointJSON: "{}")
    let segments = try CaptionTranscriptBuilder.build(
      cues: [CaptionCue(start: 0, end: 1, text: "Small changes")], source: .creatorCaption,
      sampleRate: 48_000, frameCount: 96_000)
    let audio = MediaAsset(
      id: UUID(), lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/timing.m4a", checksum: "timing-audio", format: "m4a",
      sampleRate: 48_000, frameCount: 96_000, createdAt: Date())
    try await database.publishPreparedLesson(
      lessonID: lesson.id, expectedGeneration: lesson.generation, jobID: jobID, runToken: runToken,
      title: "Timing lesson", author: nil, assets: [audio], segments: segments,
      checkpointJSON: "{\"phase\":\"ready\"}")

    let original = try #require(
      try await database.practiceTargets(lessonID: lesson.id, paths: paths).first)
    let originalTokens = try JSONDecoder().decode(
      [TranscriptWordToken].self, from: Data(try #require(segments.first).tokensJSON.utf8))
    let correctedTokens = originalTokens.enumerated().map { index, token in
      TranscriptWordToken(
        id: token.id, text: token.text, startFrame: 1_000 + index * 10_000,
        endFrame: 9_000 + index * 10_000, needsTimingReview: false)
    }
    let automatic = Data("automatic IPA".utf8)
    let manual = Data("manual IPA".utf8)
    try await database.storeAutomaticAnnotation(
      revisionID: original.segmentRevisionID, kind: .ipa, lookupKey: "caption-0-word-0:uk",
      source: "britfone", value: automatic)
    try await database.storeAnnotationOverride(
      revisionID: original.segmentRevisionID, kind: .ipa, lookupKey: "caption-0-word-0:uk",
      source: "manual", value: manual)

    let result = try await database.publishTimingRevision(
      SegmentTimingRevisionDraft(
        segmentID: original.segmentID, expectedRevisionID: original.segmentRevisionID,
        startFrame: 1_000, endFrame: 30_000, tokens: correctedTokens,
        resolvesTimingReview: true))
    let current = try #require(
      try await database.practiceTargets(lessonID: lesson.id, paths: paths).first)
    #expect(result.previousRevisionID == original.segmentRevisionID)
    #expect(current.segmentRevisionID == result.revisionID)
    #expect(current.segmentRevisionID != original.segmentRevisionID)
    #expect(current.startFrame == 1_000)
    #expect(current.endFrame == 30_000)
    #expect(current.playbackEndFrame == 30_000)
    let prepared = try #require(
      try await database.preparedPracticeSentences(lessonID: lesson.id, paths: paths).first)
    #expect(prepared.target.segmentRevisionID == result.revisionID)
    #expect(prepared.tokens == correctedTokens)
    #expect(prepared.hasManualTiming)
    let aligner = WordAlignmentPreparationTests.Stub()
    let repair = AlignedWordTimingPreparer(service: ProductionPracticeService(database: database, paths: paths), aligner: aligner)
    #expect(try await repair.prepare(sentences: [prepared], localeIdentifier: "en-GB") == false)
    #expect(await aligner.calls == 0)
    #expect(prepared.baseline.wordTimingNeedsReview == false)
    #expect(prepared.baseline.originalTokens == originalTokens)
    #expect(
      prepared.lessonSentence(number: 1).baseline?.words.map(\.span)
        == originalTokens.map { token in
          guard let start = token.startFrame, let end = token.endFrame else { return nil }
          return AudioSpan(start: Double(start) / 48_000, end: Double(end) / 48_000)
        })
    let copied = try #require(
      try await database.annotations(revisionID: result.revisionID).first(where: {
        $0.kind == .ipa && $0.lookupKey == "caption-0-word-0:uk"
      }))
    #expect(copied.automaticValue == automatic)
    #expect(copied.overrideValue == manual)
    #expect(prepared.annotations.contains(copied))

    do {
      _ = try await database.publishTimingRevision(
        SegmentTimingRevisionDraft(
          segmentID: original.segmentID, expectedRevisionID: original.segmentRevisionID,
          startFrame: 1_000, endFrame: 30_000, tokens: correctedTokens,
          resolvesTimingReview: true))
      Issue.record("A stale timing editor must not overwrite the current revision")
    } catch let error as ProductionDatabaseError {
      #expect(error == .staleLessonGeneration(expected: 0))
    }
  }

  @MainActor @Test func productionWaveformComesFromLocalAudioSamples() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audioURL = root.appendingPathComponent("waveform.caf")
    try writeAudioFixture(to: audioURL)
    let audio = try AVAudioFile(forReading: audioURL)
    let paths = BackendPaths(root: root.appendingPathComponent("backend"))
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let service = ProductionPracticeService(database: database, paths: paths)
    let values = try await service.waveformSamples(
      audioURL: audioURL, sampleRate: Int(audio.processingFormat.sampleRate),
      duration: Double(audio.length) / audio.processingFormat.sampleRate, count: 64)
    #expect(values.count == 64)
    #expect(values.contains { $0 > 0 })
    #expect(values.allSatisfy { (0...1).contains($0) })
  }

  @Test func localAudioImportPublishesOnlyM4AAndDeletesTogether() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("fixture.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let service = ProductionImportService(
      database: database, paths: paths, usesSpeechFallback: false)
    let job = try await service.submit(
      .localAudio(url: source, securityScoped: false, titleOverride: "Local fixture"))

    var ready: LibraryLessonSummary?
    for _ in 0..<200 {
      ready = try await service.librarySummaries().first(where: {
        $0.id == job.lessonID && $0.lifecycle == .ready
      })
      if ready != nil { break }
      if let failed = try await service.importJobs().first(where: {
        $0.id == job.id && $0.phase == .failed
      }) {
        Issue.record("Local import failed: \(String(describing: failed.error))")
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }

    let summary = try #require(ready)
    #expect(summary.duration != nil && summary.duration! > 0)
    let media = try FileManager.default.contentsOfDirectory(
      at: paths.sourceAudio, includingPropertiesForKeys: nil)
    #expect(media.count == 1)
    #expect(media[0].pathExtension == "m4a")
    #expect(!media.contains { ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased()) })

    let removal = FailingRemoval()
    let failingService = ProductionImportService(
      database: database, paths: paths, removeManagedItem: { try removal.remove($0) })
    do {
      try await failingService.deleteLesson(id: summary.id, expectedGeneration: summary.generation)
      Issue.record("Injected media deletion failure was ignored")
    } catch FixtureFailure.deletion {
      #expect(try await database.lesson(id: summary.id).lifecycle == .deleting)
      #expect(FileManager.default.fileExists(atPath: paths.deletionManifest(for: summary.id).path))
    }

    let recoveringService = ProductionImportService(database: database, paths: paths)
    try await recoveringService.resumePendingJobs()
    #expect(try await database.lessonCount() == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.sourceAudio.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.deletionManifest(for: summary.id).path))
  }

  @Test func subprocessStreamsLiteralArgumentsAndReportsCancellation() async throws {
    let runner = SubprocessRunner()
    let streamed = LockedOutput()
    let output = try await runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf '%s' \"$1\"", "fixture", "hello world"],
      onOutput: { streamed.append($0) })
    #expect(output.standardOutput == "hello world")
    #expect(streamed.value == "hello world")

    let workspace = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let environment = try await runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        "test -d \"$TMPDIR\" && test \"$TMPDIR\" = \"$TEMP\" && test \"$TMPDIR\" = \"$TMP\" && touch \"$TMPDIR/write-probe\" && printf '%s' \"$TMPDIR\"",
      ],
      currentDirectory: workspace)
    let expectedTemporaryDirectory = workspace.appendingPathComponent(
      "HelperTemporaryFiles", isDirectory: true)
    #expect(environment.standardOutput == expectedTemporaryDirectory.path)
    #expect(
      FileManager.default.fileExists(
        atPath: expectedTemporaryDirectory.appendingPathComponent("write-probe").path))

    let sleeping = Task {
      try await runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 10"])
    }
    try await Task.sleep(for: .milliseconds(100))
    sleeping.cancel()
    do {
      _ = try await sleeping.value
      Issue.record("Cancelled subprocess completed successfully")
    } catch let error as SubprocessError {
      #expect(error == .cancelled)
    }
  }

  @Test func bundledYTDLPStartsInsideTheSandbox() async throws {
    let workspace = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let tools = try BundledImportToolchain().resolve()
    let output = try await SubprocessRunner().run(
      executable: tools.ytDLP, arguments: ["--version"], currentDirectory: workspace)
    #expect(output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "2026.08.19")
  }

  @MainActor @Test func productionPracticeRequiresListeningBeforeCapture() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let service = ProductionPracticeService(database: fixture.database, paths: fixture.paths)
    let policy = try ProductionCapturePolicy(
      countdown: 0, trailingSilence: 1, maximumDuration: 5)
    do {
      _ = try await service.startCapture(
        target: fixture.target, sourceSpeed: 1, policy: policy)
      Issue.record("Capture started before source playback completed")
    } catch let error as ProductionPracticeError {
      #expect(error == .sourceMustBeListenedFirst)
    }
  }

  @MainActor @Test(arguments: [false, true]) func retainedTakeManifestCommitsAfterRelaunch(trim: Bool) async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let targetJSON = String(
      decoding: try JSONEncoder().encode(fixture.target.snapshot), as: UTF8.self)
    #expect(!targetJSON.contains(root.path))
    let ids = try await fixture.database.beginPracticeCapture(
      target: fixture.target, sessionID: nil, sourceSpeed: 0.85, targetJSON: targetJSON)
    let staging = fixture.paths.takeStaging.appendingPathComponent("\(ids.takeID.uuidString).caf")
    let final = fixture.paths.finalTakes.appendingPathComponent("\(ids.takeID.uuidString).caf")
    let manifestURL = fixture.paths.takeStaging.appendingPathComponent(
      "\(ids.takeID.uuidString).json")
    if trim { try RecordingSilenceTrimmerTests.fixture(to: staging) }
    else { try writeAudioFixture(to: staging) }
    let captured = try AVAudioFile(forReading: staging)
    let bytes = try Data(contentsOf: staging)
    let manifest = TakeCommitManifest(
      handle: ProductionCaptureHandle(
        sessionID: ids.sessionID, roundID: ids.roundID, takeID: ids.takeID,
        target: fixture.target, sourceSpeed: 0.85, stagingURL: staging,
        finalURL: final, manifestURL: manifestURL),
      assetID: UUID(),
      checksum: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      sampleRate: Int(captured.processingFormat.sampleRate),
      frameCount: Int(captured.length), outcome: .complete,
      trimPolicy: trim ? RecordingSilenceTrimmer.policy : nil)
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

    let relaunched = ProductionPracticeService(
      database: fixture.database, paths: fixture.paths)
    if trim {
      // Crash after receipt publication but before final rename: retry regenerates
      // the same output, then another launch sees final audio before DB commit.
      let result = try RecordingSilenceTrimmer.publish(manifest)
      try FileManager.default.removeItem(at: final)
      let recovered = try RecordingSilenceTrimmer.publish(manifest)
      #expect(result.checksum == recovered.checksum)
      #expect(recovered.plan.frameCount < manifest.frameCount)
    }
    try await relaunched.recoverPendingTakes()
    let takes = try await fixture.database.practiceTakes(lessonID: fixture.target.lessonID)
    #expect(takes.count == 1)
    #expect(takes[0].id == ids.takeID)
    #expect(takes[0].outcome == .complete)
    #expect(takes[0].status == "ready")
    if trim {
      let receipt = try JSONDecoder().decode(RecordingTrimReceipt.self,
        from: Data(contentsOf: RecordingSilenceTrimmer.receiptURL(for: final)))
      #expect(takes[0].frameCount == receipt.plan.frameCount)
      #expect(receipt.originalChecksum == manifest.checksum)
      #expect(try RecordingSilenceTrimmer.checksum(final) == receipt.checksum)
      // Recovery is idempotent even if interrupted just after committing the DB.
      try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
      try await relaunched.recoverPendingTakes()
      #expect(try await fixture.database.practiceTakes(lessonID: fixture.target.lessonID).count == 1)
    }
    #expect(FileManager.default.fileExists(atPath: final.path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

    let secondIDs = try await fixture.database.beginPracticeCapture(
      target: fixture.target, sessionID: ids.sessionID, sourceSpeed: 1, targetJSON: targetJSON)
    let secondStaging = fixture.paths.takeStaging.appendingPathComponent(
      "\(secondIDs.takeID.uuidString).caf")
    let secondFinal = fixture.paths.finalTakes.appendingPathComponent(
      "\(secondIDs.takeID.uuidString).caf")
    let secondManifestURL = fixture.paths.takeStaging.appendingPathComponent(
      "\(secondIDs.takeID.uuidString).json")
    try writeAudioFixture(to: secondStaging)
    let secondAudio = try AVAudioFile(forReading: secondStaging)
    let secondBytes = try Data(contentsOf: secondStaging)
    let secondManifest = TakeCommitManifest(
      handle: ProductionCaptureHandle(
        sessionID: secondIDs.sessionID, roundID: secondIDs.roundID,
        takeID: secondIDs.takeID, target: fixture.target, sourceSpeed: 1,
        stagingURL: secondStaging, finalURL: secondFinal,
        manifestURL: secondManifestURL),
      assetID: UUID(),
      checksum: SHA256.hash(data: secondBytes).map {
        String(format: "%02x", $0)
      }.joined(), sampleRate: Int(secondAudio.processingFormat.sampleRate),
      frameCount: Int(secondAudio.length), outcome: .noSpeech)
    try JSONEncoder().encode(secondManifest).write(to: secondManifestURL, options: .atomic)
    try await relaunched.recoverPendingTakes()
    let allTakes = try await fixture.database.practiceTakes(
      lessonID: fixture.target.lessonID)
    #expect(allTakes.count == 2)
    #expect(Set(allTakes.map(\.id)).count == 2)
    #expect(Set(allTakes.map(\.roundID)).count == 2)
    #expect(allTakes.map(\.outcome) == [.complete, .noSpeech])

    let deletion = ProductionImportService(database: fixture.database, paths: fixture.paths)
    try await deletion.deleteLesson(
      id: fixture.target.lessonID, expectedGeneration: fixture.target.lessonGeneration)
    #expect(try await fixture.database.lessonCount() == 0)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.paths.finalTakes.path
      ).isEmpty)
  }

  @Test func captureOutcomeNeverTurnsNoSpeechIntoAZeroScore() throws {
    let policy = try ProductionCapturePolicy(
      countdown: 0, trailingSilence: 1, maximumDuration: 5,
      speechThresholdDB: -42, quietThresholdDB: -34, minimumSpeechDuration: 0.2)
    let url = URL(fileURLWithPath: "/tmp/take.caf")
    #expect(
      ProductionCaptureArtifact(
        url: url, sampleRate: 1_000, frameCount: 1_000, peakDB: -120, voicedFrames: 0
      ).outcome(policy: policy, interrupted: false) == .noSpeech)
    #expect(
      ProductionCaptureArtifact(
        url: url, sampleRate: 1_000, frameCount: 1_000, peakDB: -38, voicedFrames: 500
      ).outcome(policy: policy, interrupted: false) == .quiet)
    #expect(
      ProductionCaptureArtifact(
        url: url, sampleRate: 1_000, frameCount: 1_000, peakDB: -20, voicedFrames: 500
      ).outcome(policy: policy, interrupted: false) == .complete)
    #expect(
      ProductionCaptureArtifact(
        url: url, sampleRate: 1_000, frameCount: 1_000, peakDB: -20, voicedFrames: 500
      ).outcome(policy: policy, interrupted: true) == .interrupted)
  }

  @Test func captureWriterPersistsFramesAndDetectsVoice() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("writer.caf")
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: 44_100, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let writer = CaptureWriter(file: file, url: url, thresholdDB: -42,
      nativeSampleRate: 44_100, channelCount: 1)
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { channel[index] = 0.1 }
    writer.consume(buffer)
    let snapshot = writer.snapshot()
    #expect(snapshot.error == nil)
    #expect(snapshot.frameCount == 4_410)
    #expect(snapshot.voicedFrames == 4_410)
    #expect(snapshot.peakDB > -21 && snapshot.peakDB < -19)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func retainedCommitManifestReplaysRenameBeforeDatabaseCommit() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(
      NewLesson(provider: "local", externalID: UUID().uuidString, title: "Recovering"))
    let jobID = UUID()
    let runToken = UUID()
    let checkpoint = ImportCheckpoint(
      phase: .publishing, workspaceRelativePath: "Cache/ImportJobs/\(jobID.uuidString)",
      manifestRelativePath: nil, detail: nil, updatedAt: Date())
    let input = RecoveryInput(
      kind: "localAudio", provider: "local", externalID: lesson.externalID,
      sourceURL: root.appendingPathComponent("gone.wav"), title: lesson.title,
      lessonID: lesson.id, securityScoped: false)
    try await database.persistImportJob(
      id: jobID, lessonID: lesson.id, expectedGeneration: lesson.generation, runToken: runToken,
      inputJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
      checkpointJSON: String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self))

    let assetID = UUID()
    let finalURL = paths.sourceAudio.appendingPathComponent("\(assetID.uuidString).m4a")
    let bytes = Data("published-audio".utf8)
    try bytes.write(to: finalURL)
    let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let asset = MediaAsset(
      id: assetID, lessonID: lesson.id, role: .sourceAudio,
      relativePath: "Media/SourceAudio/\(assetID.uuidString).m4a", checksum: checksum,
      format: "m4a", sampleRate: 48_000, frameCount: 48_000, createdAt: Date())
    let manifest = RecoveryManifest(
      lessonID: lesson.id, expectedGeneration: lesson.generation,
      title: "Recovered", author: nil, assets: [asset])
    let workspace = paths.importWorkspace(for: jobID)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try JSONEncoder().encode(manifest).write(
      to: workspace.appendingPathComponent("commit-manifest.json"))

    let service = ProductionImportService(database: database, paths: paths)
    try await service.resumePendingJobs()
    for _ in 0..<100 {
      if try await database.lesson(id: lesson.id).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try await database.lesson(id: lesson.id).lifecycle == .ready)
    #expect(try await database.lesson(id: lesson.id).title == "Recovered")
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func appleImportPreparesTimingAndPreservesLocaleOnRetryWithoutFallback() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("apple-fixture.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let engine = AppleImportEngineSpy()
    let importer = ProductionImportService(database: database, paths: paths, audioTranscriber: engine)
    let job = try await importer.submit(
      .localAudio(url: source, securityScoped: false, titleOverride: "Apple fixture"), localeIdentifier: "en-US")
    for _ in 0..<200 {
      if try await importer.importJobs().contains(where: { $0.id == job.id && $0.phase == .failed }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await database.lesson(id: job.lessonID).lifecycle != .ready)
    let stored = try #require(try await database.unfinishedImportJobs().first { $0.id == job.id })
    #expect(stored.inputJSON.contains("en-US"))
    #expect(await engine.events == ["prepare:en-US", "transcribe:en-US"])
    await engine.allowSuccess()
    try await importer.retry(jobID: job.id)
    for _ in 0..<200 {
      if try await database.lesson(id: job.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let summary = try #require(try await importer.librarySummaries().first { $0.id == job.lessonID })
    #expect(summary.isPracticeReady)
    #expect(summary.preparedSentenceCount == 1)
    #expect(summary.wordTimingReviewCount == 1)
    let sentences = try await ProductionPracticeService(database: database, paths: paths).preparedSentences(lessonID: job.lessonID)
    let sentence = try #require(sentences.first)
    #expect(sentence.target.text == "Hello world.")
    #expect(sentence.baseline.source == .appleSpeechAnalyzer)
    #expect(sentence.baseline.transcription?.localeIdentifier == "en-US")
    #expect(sentence.tokens[0].startFrame == 0)
    #expect(sentence.tokens[1].startFrame == nil)
    #expect(await engine.events == ["prepare:en-US", "transcribe:en-US", "prepare:en-US", "transcribe:en-US"])
  }

  @Test func combinedImportKeepsPrimaryWhenOptionalAppleFails() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("combined.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let apple = AppleImportEngineSpy()
    let primary = CombinedAdapterSpy()
    let importer = ProductionImportService(database: database, paths: paths, usesSpeechFallback: false,
      audioTranscriber: apple, transcriptionAdapters: TranscriptionAdapterRegistry([primary]))
    let job = try await importer.submit(.localAudio(url: source, securityScoped: false, titleOverride: "Combined"),
      localeIdentifier: "en-US", transcriptionEngine: "combined-test", transcriptionModelID: "combined-model")
    for _ in 0..<200 {
      if try await database.lesson(id: job.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await database.lesson(id: job.lessonID).lifecycle == .ready)
    #expect(await primary.models == ["combined-model"])
    #expect(await apple.events == ["prepare:en-US", "transcribe:en-US"])
    let sentences = try await ProductionPracticeService(database: database, paths: paths).preparedSentences(lessonID: job.lessonID)
    #expect(sentences.first?.baseline.reconciliation?.primary?.model == "combined-model")
    #expect(sentences.first?.baseline.reconciliation?.whisperModel == nil)
    #expect(sentences.first?.baseline.reconciliation?.apple == nil)
    #expect(sentences.first?.baseline.reconciliation?.secondaryUnavailable == true)
    let files = try FileManager.default.contentsOfDirectory(at: paths.root.appendingPathComponent("Media/Captions"), includingPropertiesForKeys: nil)
    let archive = try JSONDecoder().decode(CombinedTranscriptArchive.self, from: Data(contentsOf: #require(files.first)))
    #expect(archive.primary?.source == .parakeet)
    #expect(archive.whisperWords.isEmpty && archive.whisperModel == nil)
    #expect(archive.appleFailure != nil && archive.apple == nil)
    #expect(archive.captionSource == nil && archive.captions.isEmpty)
  }

  @Test(arguments: [false, true]) func adapterSelectionSurvivesFailureAndRetryWithoutApple(changeModel: Bool) async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("adapter.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let adapter = ImportAdapterSpy()
    let alignment = WordAlignmentPreparationTests.Stub()
    let importer = ProductionImportService(database: database, paths: paths, usesSpeechFallback: false,
      transcriptionAdapters: TranscriptionAdapterRegistry([adapter]), wordAligner: alignment)
    let job = try await importer.submit(.localAudio(url: source, securityScoped: false, titleOverride: nil),
      transcriptionEngine: "test-adapter", transcriptionModelID: "test-model", compareWithApple: false)
    for _ in 0..<200 {
      if try await importer.importJobs().contains(where: { $0.id == job.id && $0.phase == .failed }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let stored = try #require(try await database.unfinishedImportJobs().first)
    #expect(stored.inputJSON.contains("test-adapter") && stored.inputJSON.contains("test-model"))
    await adapter.allowSuccess()
    let nextModel = changeModel ? "test-model-2" : "test-model"
    try await importer.retry(jobID: job.id, replacementSelection: changeModel
      ? TranscriptionSelection(engineID: "test-adapter", modelID: nextModel) : nil)
    for _ in 0..<200 {
      if try await database.lesson(id: job.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await database.lesson(id: job.lessonID).lifecycle == .ready)
    #expect(await adapter.models == ["test-model", nextModel])
    let sentences = try await ProductionPracticeService(database: database, paths: paths).preparedSentences(lessonID: job.lessonID)
    #expect(await alignment.calls == 1)
    #expect(sentences.first?.baseline.alignment?.provenance.engine == "fixture")
    #expect(sentences.first?.baseline.source == .parakeet)
    #expect(sentences.first?.baseline.transcription?.model == nextModel)
    #expect(sentences.first?.baseline.reconciliation?.whisperModel == nil)
  }

  @Test func reimportingCancelledSourceResumesItsJobAndPreservesReadyLesson() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("reimport.wav")
    try writeAudioFixture(to: source)
    let db = try ProductionDatabase(url: paths.database)
    let engine = AppleImportEngineSpy()
    await engine.suspendTranscription()
    let service = ProductionImportService(database: db, paths: paths, usesSpeechFallback: false, audioTranscriber: engine)
    let request = ProductionImportRequest.localAudio(url: source, securityScoped: false, titleOverride: "Reimport")
    let first = try await service.submit(request, localeIdentifier: "en-US")
    for _ in 0..<200 {
      if await engine.events.count == 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    await service.cancel(jobID: first.id)
    for _ in 0..<200 {
      if try await service.importJobs().contains(where: { $0.id == first.id && $0.phase == .cancelled }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    await engine.allowSuccess()
    let second = try await service.submit(request, localeIdentifier: "en-GB")
    #expect(first.id == second.id && first.lessonID == second.lessonID)
    #expect(first.runToken != second.runToken)
    for _ in 0..<200 {
      if try await db.lesson(id: first.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await db.lessonCount() == 1)
    #expect(try await db.lesson(id: first.lessonID).lifecycle == .ready)
    #expect(await engine.events == ["prepare:en-US", "transcribe:en-US", "prepare:en-US", "transcribe:en-US"])
    do { _ = try await service.submit(request); Issue.record("A ready lesson must not be replaced") }
    catch let error as ProductionImportError { #expect(error == .duplicateIdentity) }
  }

  @Test func retryWaitsForOldDecoderToFinishCancellation() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("retry-wait.wav")
    try writeAudioFixture(to: source)
    let db = try ProductionDatabase(url: paths.database)
    let primary = RestartAdapterSpy()
    let apple = AppleImportEngineSpy()
    await apple.allowSuccess()
    let service = ProductionImportService(database: db, paths: paths, usesSpeechFallback: false,
      audioTranscriber: apple, transcriptionAdapters: TranscriptionAdapterRegistry([primary]))
    let first = try await service.submit(.localAudio(url: source, securityScoped: false, titleOverride: "Restart"),
      transcriptionEngine: "restart-test", transcriptionModelID: "restart-model")
    for _ in 0..<200 {
      if await primary.calls == 1 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let restarted = try await service.retry(jobID: first.id)
    #expect(restarted.runToken != first.runToken)
    for _ in 0..<200 {
      if try await db.lesson(id: first.lessonID).lifecycle == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await db.lesson(id: first.lessonID).lifecycle == .ready)
    #expect(await primary.calls == 2)
    #expect(await primary.maximumActive == 1)
    #expect(try await db.importAttempts(jobID: first.id).map(\.status) == ["cancelled", "succeeded"])
  }

  @Test func cancellingAppleTranscriptionMarksTheImportCancelled() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let source = root.appendingPathComponent("apple-cancel.wav")
    try writeAudioFixture(to: source)
    let database = try ProductionDatabase(url: paths.database)
    let engine = AppleImportEngineSpy()
    await engine.suspendTranscription()
    let importer = ProductionImportService(database: database, paths: paths, audioTranscriber: engine)
    let job = try await importer.submit(.localAudio(url: source, securityScoped: false, titleOverride: nil))
    for _ in 0..<200 {
      if await engine.events.count == 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await engine.events.count == 2)
    await importer.cancel(jobID: job.id)
    var cancelled = false
    for _ in 0..<200 {
      cancelled = try await importer.importJobs().contains { $0.id == job.id && $0.phase == .cancelled }
      if cancelled { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(cancelled)
    #expect(try await database.lesson(id: job.lessonID).lifecycle != .ready)
  }

  @MainActor @Test func contentMatchingQueuePersistsAndKeepsOldResults() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let adapter = MatchingTestAdapter()
    let service = ContentMatchingService(database: fixture.database, paths: fixture.paths,
      adapters: TranscriptionAdapterRegistry([adapter]))
    service.practiceIsBusy = { true }
    var preferences = Preferences()
    preferences.transcriptionEngine = "test-matching"
    preferences.activeTranscriptionModel = "model-a"
    await service.enqueue(take, preferences: preferences)
    await service.enqueue(take, preferences: preferences)
    #expect(service.history(takeID: take.id).count == 1)
    let queued = try #require(service.jobs.first)
    #expect(queued.status == .queued)
    #expect(queued.target == fixture.target.snapshot)
    preferences.activeTranscriptionModel = "model-b"
    service.practiceIsBusy = { false }
    for _ in 0..<100 {
      if service.history(takeID: take.id).last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let first = try #require(service.history(takeID: take.id).last)
    #expect(first.status == .complete)
    #expect(first.match?.differences.isEmpty == true)
    #expect(first.selection.modelID == "model-a")
    await service.rerun(take, preferences: preferences)
    for _ in 0..<100 {
      if service.history(takeID: take.id).last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let reopened = try ProductionDatabase(url: fixture.paths.database)
    let history = try await reopened.contentMatchingJobs()
    #expect(history.count == 2)
    #expect(history.first?.id == first.id)
    #expect(history.last?.selection.modelID == "model-b")
    #expect(await adapter.models == ["model-a", "model-b"])
    var mutated = first
    mutated.status = .failed
    await #expect(throws: ProductionDatabaseError.self) {
      try await reopened.updateContentMatching(mutated)
    }
  }

  @MainActor @Test func contentMatchingRecoversRunningJobAndSurfacesFailure() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let adapter = MatchingTestAdapter()
    let selection = TranscriptionSelection(engineID: "test-matching", modelID: "model-a")
    var job = try await fixture.database.enqueueContentMatching(takeID: take.id, selection: selection,
      locale: "en-GB", provenance: adapter.provenance(modelID: "model-a", locale: "en-GB"))
    job.status = .running
    try await fixture.database.updateContentMatching(job)
    await adapter.failNext()
    let relaunched = ContentMatchingService(database: fixture.database, paths: fixture.paths,
      adapters: TranscriptionAdapterRegistry([adapter]))
    await relaunched.recover()
    for _ in 0..<100 {
      if relaunched.jobs.last?.status == .failed { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let failed = try #require(relaunched.jobs.last)
    #expect(failed.status == .failed)
    #expect(failed.error != nil)
    #expect(failed.match == nil)
    await relaunched.retry(failed)
    for _ in 0..<100 {
      if relaunched.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(relaunched.jobs.count == 2)
    #expect(relaunched.jobs.first?.status == .failed)
    #expect(relaunched.jobs.last?.status == .complete)
    #expect(relaunched.jobs.last?.selection == selection)
  }

  @MainActor @Test func matchingRejectsNoSpeechQuietInterruptedAndChangedAudio() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let adapter = MatchingTestAdapter()
    for outcome in [CaptureOutcome.noSpeech, .quiet, .interrupted] {
      let take = try await matchingTake(fixture: fixture, outcome: outcome)
      await #expect(throws: ProductionDatabaseError.self) {
        try await fixture.database.enqueueContentMatching(takeID: take.id,
          selection: .init(engineID: "test-matching", modelID: "a"), locale: "en-GB",
          provenance: adapter.provenance(modelID: "a", locale: "en-GB"))
      }
    }
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    try Data("changed".utf8).write(to: fixture.paths.finalTakes.appendingPathComponent("\(take.id.uuidString).caf"))
    let service = ContentMatchingService(database: fixture.database, paths: fixture.paths,
      adapters: TranscriptionAdapterRegistry([adapter]))
    var preferences = Preferences()
    preferences.transcriptionEngine = "test-matching"
    preferences.activeTranscriptionModel = "a"
    await service.enqueue(take, preferences: preferences)
    for _ in 0..<100 {
      if service.jobs.last?.status == .failed { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(service.jobs.last?.status == .failed)
    #expect(await adapter.models.isEmpty)
  }

  @MainActor @Test func deletingLessonRemovesMatchingJobsAndRejectsLateResults() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let adapter = MatchingTestAdapter()
    var job = try await fixture.database.enqueueContentMatching(takeID: take.id,
      selection: .init(engineID: "test-matching", modelID: "a"), locale: "en-GB",
      provenance: adapter.provenance(modelID: "a", locale: "en-GB"))
    let generation = try await fixture.database.markLessonDeleting(id: fixture.target.lessonID,
      expectedGeneration: fixture.target.lessonGeneration)
    try await fixture.database.completeLessonDeletion(lessonID: fixture.target.lessonID,
      expectedGeneration: generation)
    job.status = .complete
    await #expect(throws: ProductionDatabaseError.self) { try await fixture.database.updateContentMatching(job) }
    #expect(try await fixture.database.contentMatchingJobs().isEmpty)
    #expect(try await fixture.database.integrityCheck() == "ok")
  }

  @MainActor @Test func matchingKeepsTheRecordedTargetAfterTimingRevisionChanges() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let changed = try await fixture.database.publishTimingRevision(SegmentTimingRevisionDraft(
      segmentID: fixture.target.segmentID, expectedRevisionID: fixture.target.segmentRevisionID,
      startFrame: fixture.target.startFrame + 10, endFrame: fixture.target.endFrame,
      tokens: [TranscriptWordToken(id: "practice-word", text: "Practice", startFrame: nil, endFrame: nil, needsTimingReview: true),
        TranscriptWordToken(id: "target-word", text: "target", startFrame: nil, endFrame: nil, needsTimingReview: true)],
      resolvesTimingReview: false))
    #expect(changed.revisionID != take.segmentRevisionID)
    let saved = try await fixture.database.savedTakeSentences(lessonID: take.lessonID, paths: fixture.paths)
    #expect(saved[take.id]?.target.snapshot == fixture.target.snapshot)
    let adapter = MatchingTestAdapter()
    let job = try await fixture.database.enqueueContentMatching(takeID: take.id,
      selection: .init(engineID: "test-matching", modelID: "a"), locale: "en-GB",
      provenance: adapter.provenance(modelID: "a", locale: "en-GB"))
    #expect(job.target == fixture.target.snapshot)
  }

  @Test func migrationFromV1RetainsExistingLessons() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(NewLesson(provider: "test", externalID: "migration", title: "Keep me"))
    var raw: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let connection = try #require(raw)
    #expect(sqlite3_exec(connection, "DROP TABLE dictation_progress; DROP TABLE content_matching_jobs; DROP TABLE pronunciation_jobs; PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(connection)
    let upgraded = try ProductionDatabase(url: paths.database)
    #expect(try await upgraded.schemaVersion() == ProductionDatabase.currentSchemaVersion)
    #expect(try await upgraded.lesson(id: lesson.id).title == "Keep me")
    #expect(try await upgraded.contentMatchingJobs().isEmpty)
    #expect(try await upgraded.integrityCheck() == "ok")
  }

  @MainActor @Test func openingLegacyAssessmentAppendsDeliveryWithoutRewritingHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    _ = try await fixture.database.enqueuePronunciation(takeID: take.id, words: [], accent: .uk,
      provenance: BuddyModelPackage.provenance, force: false)
    var old = try #require(try await fixture.database.pronunciationJobs().last)
    old.status = .complete
    old.result = PronunciationEvidence(words: [], duration: 1, recognizedPhones: [])
    try await fixture.database.updatePronunciation(old)
    let assessment = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: PronunciationTestAdapter())
    let practice = ProductionPracticeService(database: fixture.database, paths: fixture.paths)
    let model = ProductionShadowingModel(service: practice, controller: ProductionPracticeController(service: practice),
      dictation: DictationModel(storage: fixture.database),
      assessmentService: assessment)
    var preferences = Preferences()
    preferences.productionAssessmentEngine = .buddy
    await model.assessIfNeeded(take, preferences: preferences)
    for _ in 0..<100 {
      if assessment.jobs.last?.status == .complete && assessment.jobs.count == 2 { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let jobs = try await fixture.database.pronunciationJobs()
    #expect(jobs.count == 2)
    #expect(jobs.first == old)
    #expect(jobs.last?.result?.delivery != nil)
    await model.assessIfNeeded(take, preferences: preferences)
    #expect(try await fixture.database.pronunciationJobs() == jobs)
  }

  @MainActor @Test func UKSelectionRunsOneEngineAndRescoringKeepsEarlierResult() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let buddy = PronunciationTestAdapter(), uk = UKQueueTestScorer(), phone = UKQueueTestScorer()
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: buddy, scorer: phone, ukScorer: uk)
    var preferences = Preferences()
    preferences.productionAssessmentEngine = .ukReference
    preferences.accent = .uk
    await service.enqueue(take, preferences: preferences)
    for _ in 0..<100 {
      if service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let original = try #require(service.jobs.last)
    #expect(original.status == .complete && original.provenance == UKReferencePackage.provenance)
    #expect(original.accent == .uk)
    #expect(await uk.calls == 1)
    #expect(await buddy.calls == 0)
    #expect(await phone.calls == 0)
    await service.enqueue(take, preferences: preferences)
    #expect(try await fixture.database.pronunciationJobs() == [original])
    await service.enqueue(take, preferences: preferences, force: true)
    for _ in 0..<100 {
      if service.jobs.count == 2 && service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let history = try await fixture.database.pronunciationJobs()
    #expect(history.count == 2 && history.first == original)
    #expect(await uk.calls == 2)
    #expect(await buddy.calls == 0)
    #expect(await phone.calls == 0)
  }

  /// Spec L4: the XEUS helper and its encoder session stay warm between jobs, so moving to another
  /// engine must hand the memory back. A second XEUS job must not release anything.
  @MainActor @Test func movingOffPhoneticXeusReleasesItsWarmHelper() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let xeus = UKQueueTestScorer(), buddy = PronunciationTestAdapter()
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: buddy, xeusScorer: xeus)
    var preferences = Preferences()
    preferences.productionAssessmentEngine = .phoneticXeus
    preferences.accent = .uk
    await service.enqueue(take, preferences: preferences)
    for _ in 0..<200 {
      if service.jobs.count == 1 && service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await xeus.calls == 1)
    #expect(await xeus.releases == 0)
    await service.enqueue(take, preferences: preferences, force: true)
    for _ in 0..<200 {
      if service.jobs.count == 2 && service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await xeus.calls == 2)
    #expect(await xeus.releases == 0)
    preferences.productionAssessmentEngine = .buddy
    await service.enqueue(take, preferences: preferences, force: true)
    #expect(await xeus.releases == 1)
    for _ in 0..<200 {
      if service.jobs.count == 3 && service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await buddy.calls > 0)
    #expect(await xeus.calls == 2)
  }

  /// Spec L4: XEUS and UK Reference share one UK adapter, so moving between those two engines must
  /// keep its encoder — releasing it would make every UK Reference job cold. Only an engine that
  /// needs neither hands it back.
  @MainActor @Test func movingToUKReferenceKeepsItsEncoderAndOnlyReleasesTheXeusHelper() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let xeus = UKQueueTestScorer(), uk = UKQueueTestScorer(), buddy = PronunciationTestAdapter()
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: buddy, ukScorer: uk, xeusScorer: xeus)
    var preferences = Preferences()
    preferences.productionAssessmentEngine = .ukReference
    preferences.accent = .uk
    await service.enqueue(take, preferences: preferences)
    #expect(await xeus.releases == 1)
    #expect(await uk.releases == 0) // the encoder this very job is about to use
    for _ in 0..<200 {
      if service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await uk.calls == 1)
    preferences.productionAssessmentEngine = .buddy
    await service.enqueue(take, preferences: preferences, force: true)
    #expect(await uk.releases == 1)
    #expect(await xeus.releases == 2)
    for _ in 0..<200 {
      if service.jobs.count == 2 && service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await buddy.calls > 0)
    #expect(await uk.calls == 1)
  }

  /// Spec L4 (task-4 review, R4): `!isProcessing` alone does not protect a XEUS job that is queued
  /// but not yet running — the practice gate parks the worker with the job still pending. Enqueuing
  /// another engine in that window must not tear down the helper the queued job is about to use.
  @MainActor @Test func enqueueingAnotherEngineWhileAXeusJobIsStillQueuedReleasesNothing() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let xeus = UKQueueTestScorer(), buddy = PronunciationTestAdapter()
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: buddy, xeusScorer: xeus)
    // The worker parks on the practice gate, so the XEUS job stays queued and `isProcessing` false.
    service.practiceIsBusy = { true }
    var preferences = Preferences()
    preferences.productionAssessmentEngine = .phoneticXeus
    preferences.accent = .uk
    await service.enqueue(take, preferences: preferences)
    #expect(service.jobs.contains { $0.provenance == PhoneticXeusPackage.provenance && $0.isPending })
    #expect(service.isProcessing == false)
    preferences.productionAssessmentEngine = .buddy
    await service.enqueue(take, preferences: preferences, force: true)
    // The release hook runs before the insert, and the queued job also makes the database hand back
    // the pending job instead of adding a second one: nothing released, nothing queued.
    #expect(await xeus.releases == 0)
    #expect(service.jobs.count == 1)
    service.practiceIsBusy = { false }
    for _ in 0..<400 {
      if service.jobs.allSatisfy({ !$0.isPending }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await xeus.calls == 1)
    #expect(await xeus.releases == 0)
    // Once the queue has drained, the very same call does hand the helper back — the queued job was
    // the only thing holding it.
    await service.enqueue(take, preferences: preferences, force: true)
    #expect(await xeus.releases == 1)
    for _ in 0..<400 {
      if service.jobs.count == 2 && service.jobs.allSatisfy({ !$0.isPending }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await buddy.calls > 0)
    #expect(await xeus.calls == 1)
  }

  @MainActor @Test func openingExistingTakeUsesCurrentSelectionAndOnlyFillsMissingAssessment() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths,
      dictionary: nil, adapter: PronunciationTestAdapter())
    let practice = ProductionPracticeService(database: fixture.database, paths: fixture.paths)
    let model = ProductionShadowingModel(service: practice, controller: ProductionPracticeController(service: practice),
      dictation: DictationModel(storage: fixture.database),
      assessmentService: service)
    // The existing model predates the Settings selection; Review must pass live preferences.
    model.applyPreferences(Preferences())
    await model.assessIfNeeded(take, preferences: Preferences())
    #expect(try await fixture.database.pronunciationJobs().isEmpty)
    var current = Preferences()
    current.productionAssessmentEngine = .buddy
    await model.assessIfNeeded(take, preferences: current)
    for _ in 0..<100 {
      if service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let first = try #require(service.jobs.last)
    #expect(first.status == .complete)
    await model.assessIfNeeded(take, preferences: current)
    #expect(try await fixture.database.pronunciationJobs() == [first])
  }

  @MainActor @Test func pronunciationQueueRecoversAndRetainsImmutableHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    var queued = try await fixture.database.enqueuePronunciation(takeID: take.id, words: [], accent: .uk,
      provenance: BuddyModelPackage.provenance)
    queued.status = .running
    try await fixture.database.updatePronunciation(queued)
    let adapter = PronunciationTestAdapter()
    let service = PronunciationAssessmentService(database: fixture.database, paths: fixture.paths, dictionary: nil, adapter: adapter)
    service.practiceIsBusy = { true }
    await service.recover()
    #expect(await adapter.calls == 0)
    service.practiceIsBusy = { false }
    for _ in 0..<100 {
      if service.jobs.last?.status == .complete { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let complete = try #require(service.jobs.last)
    #expect(complete.status == .complete)
    #expect(complete.target == fixture.target.snapshot)
    #expect(complete.result?.assessedWords == 0)
    var changed = complete
    changed.status = .failed
    await #expect(throws: ProductionDatabaseError.self) { try await fixture.database.updatePronunciation(changed) }
    await adapter.failNext()
    await service.retry(complete)
    for _ in 0..<100 {
      if service.jobs.last?.status == .unrecognized { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let reopened = try ProductionDatabase(url: fixture.paths.database)
    let history = try await reopened.pronunciationJobs()
    #expect(history.count == 2)
    #expect(history.first == complete)
    #expect(history.last?.status == .unrecognized)
    #expect(history.last?.result == nil)
    #expect(history.last?.provenance == complete.provenance)
  }

  @MainActor @Test func pronunciationRejectsIneligibleTakesAndDeletedLessonResults() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    for outcome in [CaptureOutcome.noSpeech, .quiet, .interrupted] {
      let take = try await matchingTake(fixture: fixture, outcome: outcome)
      await #expect(throws: ProductionDatabaseError.self) {
        try await fixture.database.enqueuePronunciation(takeID: take.id, words: [], accent: .us, provenance: BuddyModelPackage.provenance)
      }
    }
    let take = try await matchingTake(fixture: fixture, outcome: .earlyStop)
    var job = try await fixture.database.enqueuePronunciation(takeID: take.id, words: [], accent: .us, provenance: BuddyModelPackage.provenance)
    let generation = try await fixture.database.markLessonDeleting(id: fixture.target.lessonID, expectedGeneration: fixture.target.lessonGeneration)
    try await fixture.database.completeLessonDeletion(lessonID: fixture.target.lessonID, expectedGeneration: generation)
    job.status = .complete
    await #expect(throws: ProductionDatabaseError.self) { try await fixture.database.updatePronunciation(job) }
    #expect(try await fixture.database.pronunciationJobs().isEmpty)
    #expect(try await fixture.database.integrityCheck() == "ok")
  }

  @MainActor @Test func deletingMultipleSavedRecordingsRemovesOnlyTheirFilesAndHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let first = try await matchingTake(fixture: fixture, outcome: .complete)
    let second = try await matchingTake(fixture: fixture, outcome: .noSpeech)
    let kept = try await matchingTake(fixture: fixture, outcome: .earlyStop)
    let adapter = MatchingTestAdapter()
    var matching = try await fixture.database.enqueueContentMatching(
      takeID: first.id, selection: .init(engineID: "test-matching", modelID: "a"),
      locale: "en-GB", provenance: adapter.provenance(modelID: "a", locale: "en-GB"))

    let service = ProductionPracticeService(database: fixture.database, paths: fixture.paths)
    await #expect(throws: ProductionDatabaseError.self) {
      try await service.deleteRecordings(ids: [first.id], lessonID: fixture.target.lessonID)
    }
    matching.status = .complete
    try await fixture.database.updateContentMatching(matching)

    let removed = try await service.deleteRecordings(
      ids: [first.id, second.id], lessonID: fixture.target.lessonID)
    #expect(removed > 0)
    let remaining = try await fixture.database.practiceTakes(lessonID: fixture.target.lessonID)
    #expect(remaining.map(\.id) == [kept.id])
    #expect(try await fixture.database.contentMatchingJobs().isEmpty)
    #expect(!FileManager.default.fileExists(
      atPath: fixture.paths.finalTakes.appendingPathComponent("\(first.id.uuidString).caf").path))
    #expect(!FileManager.default.fileExists(
      atPath: fixture.paths.finalTakes.appendingPathComponent("\(second.id.uuidString).caf").path))
    #expect(FileManager.default.fileExists(
      atPath: fixture.paths.finalTakes.appendingPathComponent("\(kept.id.uuidString).caf").path))
    #expect(try await fixture.database.integrityCheck() == "ok")
  }

  @Test func schemaTwoMigratesWithoutLosingContentMatching() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let take = try await matchingTake(fixture: fixture, outcome: .complete)
    let adapter = MatchingTestAdapter()
    let old = try await fixture.database.enqueueContentMatching(takeID: take.id,
      selection: .init(engineID: "test-matching", modelID: "a"), locale: "en-GB", provenance: adapter.provenance(modelID: "a", locale: "en-GB"))
    var raw: OpaquePointer?
    #expect(sqlite3_open_v2(fixture.paths.database.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let connection = try #require(raw)
    #expect(sqlite3_exec(connection, "DROP TABLE dictation_progress; DROP TABLE pronunciation_jobs; PRAGMA user_version = 2", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(connection)
    let upgraded = try ProductionDatabase(url: fixture.paths.database)
    #expect(try await upgraded.schemaVersion() == ProductionDatabase.currentSchemaVersion)
    #expect(try await upgraded.contentMatchingJobs().first?.id == old.id)
    #expect(try await upgraded.pronunciationJobs().isEmpty)
  }

  private func matchingTake(fixture: (paths: BackendPaths, database: ProductionDatabase,
    target: ProductionPracticeTarget), outcome: CaptureOutcome) async throws -> ProductionStoredTake {
    let targetJSON = String(decoding: try JSONEncoder().encode(fixture.target.snapshot), as: UTF8.self)
    let ids = try await fixture.database.beginPracticeCapture(target: fixture.target,
      sessionID: nil, sourceSpeed: 0.85, targetJSON: targetJSON)
    let handle = ProductionCaptureHandle(sessionID: ids.sessionID, roundID: ids.roundID,
      takeID: ids.takeID, target: fixture.target, sourceSpeed: 0.85,
      stagingURL: fixture.paths.takeStaging.appendingPathComponent("\(ids.takeID.uuidString).caf"),
      finalURL: fixture.paths.finalTakes.appendingPathComponent("\(ids.takeID.uuidString).caf"),
      manifestURL: fixture.paths.takeStaging.appendingPathComponent("\(ids.takeID.uuidString).json"))
    try writeAudioFixture(to: handle.finalURL)
    let checksum = SHA256.hash(data: try Data(contentsOf: handle.finalURL)).map { String(format: "%02x", $0) }.joined()
    try await fixture.database.commitPracticeTake(handle: handle, assetID: UUID(),
      relativePath: "Takes/Final/\(ids.takeID.uuidString).caf", checksum: checksum,
      sampleRate: 44_100, frameCount: 4_410, outcome: outcome)
    return try #require(try await fixture.database.practiceTakes(lessonID: fixture.target.lessonID).last)
  }

  @Test func dictationRetainsAttemptsRejectsMutationAndCascadesOnDeletion() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let target = fixture.target
    var value = DictationProgress(lessonID: target.lessonID, revisionID: target.segmentRevisionID,
      targetText: target.text, draft: .init())
    value.draft.hasListened = true; value.draft.listenCount = 1
    value.draft.answer = "practice TARGET!"
    try value.submit(timedOut: false, now: Date())
    try await fixture.database.saveDictationProgress(value)
    let reopened = try ProductionDatabase(url: fixture.paths.database)
    #expect(try await reopened.dictationProgress(lessonID: target.lessonID) == [value])
    let first = value.latest
    value.draft = .init(timeLimit: nil)
    try await reopened.saveDictationProgress(value)
    var destructive = value; destructive.attempts = []
    await #expect(throws: DictationError.self) { try await reopened.saveDictationProgress(destructive) }
    #expect(try await reopened.dictationProgress(lessonID: target.lessonID).first?.latest == first)
    let wrong = DictationProgress(lessonID: target.lessonID, revisionID: target.segmentRevisionID,
      targetText: "Changed target", draft: .init())
    await #expect(throws: DictationError.self) { try await reopened.saveDictationProgress(wrong) }
    let generation = try await reopened.markLessonDeleting(id: target.lessonID,
      expectedGeneration: target.lessonGeneration)
    await #expect(throws: DictationError.self) { try await reopened.saveDictationProgress(value) }
    try await reopened.completeLessonDeletion(lessonID: target.lessonID, expectedGeneration: generation)
    #expect(try await reopened.dictationProgress(lessonID: target.lessonID).isEmpty)
    #expect(try await reopened.integrityCheck() == "ok")
  }

  @Test func damagedDictationRowIsSkippedAndRepairedByTheNextSave() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await preparedPracticeFixture(root: root)
    let target = fixture.target
    var value = DictationProgress(lessonID: target.lessonID, revisionID: target.segmentRevisionID,
      targetText: target.text, draft: .init())
    value.draft.hasListened = true; value.draft.listenCount = 1; value.draft.answer = "practice"
    try await fixture.database.saveDictationProgress(value)
    var raw: OpaquePointer?
    #expect(sqlite3_open(fixture.paths.database.path, &raw) == SQLITE_OK)
    let connection = try #require(raw)
    #expect(sqlite3_exec(connection, "UPDATE dictation_progress SET payload = X'7B7D'", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(connection)
    let reopened = try ProductionDatabase(url: fixture.paths.database)
    #expect(try await reopened.dictationProgress(lessonID: target.lessonID).isEmpty)
    try await reopened.saveDictationProgress(value)
    #expect(try await reopened.dictationProgress(lessonID: target.lessonID) == [value])
  }

  @Test func dictationMigrationFromV3KeepsLessonsAndAssessmentTables() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    let database = try ProductionDatabase(url: paths.database)
    let lesson = try await database.insertLesson(NewLesson(provider: "test", externalID: "dictation-migration", title: "Keep me"))
    var raw: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let connection = try #require(raw)
    #expect(sqlite3_exec(connection, "DROP TABLE dictation_progress; PRAGMA user_version = 3", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(connection)
    let upgraded = try ProductionDatabase(url: paths.database)
    #expect(try await upgraded.schemaVersion() == 4)
    #expect(try await upgraded.lesson(id: lesson.id).title == "Keep me")
    #expect(try await upgraded.contentMatchingJobs().isEmpty)
    #expect(try await upgraded.pronunciationJobs().isEmpty)
    #expect(try await upgraded.dictationProgress(lessonID: lesson.id).isEmpty)
    #expect(try await upgraded.integrityCheck() == "ok")
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
      "ToSpeech-production-test-\(UUID().uuidString)", isDirectory: true)
  }
}

private final class LockedOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""

  func append(_ chunk: String) {
    lock.lock()
    text += chunk
    lock.unlock()
  }

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return text
  }
}

private enum FixtureFailure: Error { case deletion }

private final class FailingRemoval: @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false

  func remove(_ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    guard failed else {
      failed = true
      throw FixtureFailure.deletion
    }
    try FileManager.default.removeItem(at: url)
  }
}

private struct RecoveryInput: Encodable {
  let kind: String
  let provider: String
  let externalID: String
  let sourceURL: URL
  let title: String
  let lessonID: UUID
  let securityScoped: Bool
}

private struct RecoveryManifest: Encodable {
  let lessonID: UUID
  let expectedGeneration: Int
  let title: String
  let author: String?
  let assets: [MediaAsset]
}

private actor AppleImportEngineSpy: AudioTranscriptTranscribing {
  private(set) var events: [String] = []
  private var failing = true
  private var suspended = false
  func suspendTranscription() { suspended = true }
  func allowSuccess() { failing = false; suspended = false }
  func prepare(localeIdentifier: String) { events.append("prepare:\(localeIdentifier)") }
  func transcribe(audioURL: URL, localeIdentifier: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    events.append("transcribe:\(localeIdentifier)")
    if suspended { try await Task.sleep(for: .seconds(30)) }
    if failing { throw SpeechAnalyzerPreparationError.assetsUnavailable }
    onProgress(1)
    return AudioTranscription(
      words: [TimedWord(text: " Hello", start: 0, end: 0.04), TimedWord(text: " world.", start: 0.05, end: 0.05)],
      source: .appleSpeechAnalyzer,
      provenance: TranscriptionProvenance(engine: "Apple SpeechAnalyzer", model: "SpeechTranscriber", localeIdentifier: localeIdentifier, runtimeVersion: "test OS"))
  }
}

private actor CombinedAdapterSpy: TranscriptionAdapter {
  nonisolated let engineID = "combined-test"
  private(set) var models: [String] = []
  func validate(modelID: String) {}
  nonisolated func provenance(modelID: String, locale: String) -> TranscriptionProvenance {
    TranscriptionProvenance(engine: "combined-test", model: modelID, localeIdentifier: locale, runtimeVersion: "test")
  }
  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    models.append(modelID)
    onProgress(1)
    return AudioTranscription(words: [TimedWord(text: "Hello", start: 0, end: 0.04), TimedWord(text: "world.", start: 0.05, end: 0.09)],
      source: .parakeet, provenance: provenance(modelID: modelID, locale: locale))
  }
}

private actor RestartAdapterSpy: TranscriptionAdapter {
  nonisolated let engineID = "restart-test"
  private(set) var calls = 0
  private(set) var maximumActive = 0
  private var active = 0
  func validate(modelID: String) {}
  nonisolated func provenance(modelID: String, locale: String) -> TranscriptionProvenance {
    TranscriptionProvenance(engine: "restart-test", model: modelID, localeIdentifier: locale, runtimeVersion: "test")
  }
  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    calls += 1
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    if calls == 1 {
      do { try await Task.sleep(for: .seconds(30)) }
      catch {
        // Model cleanup need not complete immediately when cancellation is requested.
        await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
        throw CancellationError()
      }
    }
    return AudioTranscription(words: [TimedWord(text: "Hello", start: 0, end: 0.04), TimedWord(text: "world.", start: 0.05, end: 0.09)],
      source: .parakeet, provenance: provenance(modelID: modelID, locale: locale))
  }
}

private actor ImportAdapterSpy: TranscriptionAdapter {
  nonisolated let engineID = "test-adapter"
  private var failing = true
  private(set) var models: [String] = []
  func allowSuccess() { failing = false }
  func validate(modelID: String) throws {
    guard ["test-model", "test-model-2"].contains(modelID) else { throw TranscriptionAdapterError.unsupportedModel(modelID) }
  }
  nonisolated func provenance(modelID: String, locale: String) -> TranscriptionProvenance {
    TranscriptionProvenance(engine: "test-adapter", model: modelID, localeIdentifier: locale, runtimeVersion: "test")
  }
  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    models.append(modelID)
    if failing { throw TranscriptionAdapterError.emptyTranscript }
    return AudioTranscription(words: [TimedWord(text: "Hello", start: 0, end: 0.04), TimedWord(text: "world.", start: 0.05, end: 0.09)],
      source: .parakeet, provenance: provenance(modelID: modelID, locale: locale))
  }
}

private actor MatchingTestAdapter: TranscriptionAdapter {
  nonisolated let engineID = "test-matching"
  private(set) var models: [String] = []
  private var shouldFail = false
  func failNext() { shouldFail = true }
  func validate(modelID: String) {}
  nonisolated func provenance(modelID: String, locale: String) -> TranscriptionProvenance {
    .init(engine: "Test ASR", model: modelID, localeIdentifier: locale, runtimeVersion: "test-1")
  }
  func transcribe(audioURL: URL, modelID: String, locale: String,
    onProgress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscription {
    models.append(modelID)
    if shouldFail { shouldFail = false; throw TranscriptionAdapterError.busy }
    return AudioTranscription(words: [TimedWord(text: "Practice", start: 0, end: 0.04),
      TimedWord(text: "target", start: 0.04, end: 0.09)], source: .parakeet,
      provenance: provenance(modelID: modelID, locale: locale))
  }
}

private actor PronunciationTestAdapter: PronunciationRecognizing {
  private(set) var calls = 0
  private var shouldFail = false
  func failNext() { shouldFail = true }
  func recognize(audioURL: URL, span: AudioSpan?) async throws -> (phones: [RecognizedPhone], duration: Double) {
    calls += 1
    if shouldFail { shouldFail = false; throw BuddyError.noSpeech }
    return ([RecognizedPhone(symbol: "k", start: 0, end: 0.1, posterior: 0.9)], 0.1)
  }
}

private actor UKQueueTestScorer: PhoneScoring {
  private(set) var calls = 0
  private(set) var releases = 0
  func assess(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL,
    words: [PronunciationWordTarget], accent: ReferenceAccent) async throws -> PronunciationEvidence {
    calls += 1
    return .init(words: [], duration: 0.1, recognizedPhones: [], qualityPolicy: UKReferenceEvidence.policy)
  }
  func release() async { releases += 1 }
}
