import Foundation
import Testing

@testable import ToSpeech

struct PreviewPersistenceTests {
  @Test @MainActor func readingSizeSurvivesLessonChangesAndStoreReload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToSpeech-reading-test-\(UUID().uuidString)")
    let repository = PreviewRepository(url: directory.appendingPathComponent("snapshot.json"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: repository)
    store.preferences.readingPercent = 140
    store.openLesson(store.lessons[1].id)
    #expect(store.preferences.readingPercent == 140)
    let restored = EchoStore(repository: repository)
    #expect(restored.preferences.readingPercent == 140)
    #expect(restored.selectedLessonID == store.lessons[1].id)
    #expect(restored.storageError == nil)
  }

  @Test @MainActor func snapshotsWithRetiredEnginesStillLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToSpeech-retired-engine-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot.json")
    let repository = PreviewRepository(url: url)
    let snapshot = PreviewFixtures.snapshot()
    try repository.save(snapshot)
    // Inject what a pre-removal build wrote: a GOPT package, a GOPT assessment and
    // GOPT as the active engine.
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var packages = try #require(object["packages"] as? [[String: Any]])
    var retired = packages[0]; retired["id"] = "gopt"; packages.append(retired)
    object["packages"] = packages
    var takes = try #require(object["takes"] as? [[String: Any]])
    var assessments = takes[0]["assessments"] as? [[String: Any]] ?? []
    let originalAssessments = assessments.count
    assessments.append(["id": "gopt-run", "engine": "gopt", "version": "1", "accent": "UK", "configuration": "",
                        "status": "complete", "score": 80, "createdAt": 0])
    takes[0]["assessments"] = assessments
    object["takes"] = takes
    var preferences = try #require(object["preferences"] as? [String: Any])
    preferences["activeEngine"] = "gopt"
    object["preferences"] = preferences
    try JSONSerialization.data(withJSONObject: object).write(to: url)

    let restored = try #require(try repository.load())
    #expect(restored.lessons.count == snapshot.lessons.count)
    #expect(restored.takes.count == snapshot.takes.count)
    #expect(restored.packages.count == snapshot.packages.count)
    #expect(restored.takes[0].assessments.count == originalAssessments)
    #expect(restored.preferences.activeEngine == nil)
    #expect(EchoStore(repository: repository).storageError == nil)
  }

  @Test func youtubeIdentityRejectsLookalikeDomains() {
    #expect(YouTubeLink.videoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=2") == "dQw4w9WgXcQ")
    #expect(YouTubeLink.videoID("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    #expect(YouTubeLink.videoID("https://youtube.com.evil.invalid/watch?v=dQw4w9WgXcQ") == nil)
    #expect(YouTubeLink.videoID("https://youtube.com/playlist?list=abc") == nil)
    #expect(YouTubeLink.videoID("javascript:alert(1)") == nil)
  }

  @Test func previewMetadataRoundTripsIncludingHistoricalContext() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToSpeech-test-\(UUID().uuidString)")
    let repository = PreviewRepository(url: directory.appendingPathComponent("snapshot.json"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = PreviewFixtures.snapshot()
    try repository.save(original)
    let loaded = try repository.load()
    let restored = try #require(loaded)
    #expect(restored.lessons == original.lessons)
    #expect(restored.takes == original.takes)
    #expect(restored.preferences == original.preferences)
  }

  @Test @MainActor func corruptSnapshotIsNotOverwrittenWithFixtures() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToSpeech-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot.json")
    let corrupted = Data("invalid original data".utf8)
    try corrupted.write(to: url)
    let store = EchoStore(repository: PreviewRepository(url: url))
    #expect(store.storageError != nil)
    store.preferences.speed = 1.5
    #expect(try Data(contentsOf: url) == corrupted)
  }
}
