import Foundation
import Testing

@testable import EchoLab

struct PreviewPersistenceTests {
  @Test @MainActor func readingSizeSurvivesLessonChangesAndStoreReload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EchoLab-reading-test-\(UUID().uuidString)")
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

  @Test func youtubeIdentityRejectsLookalikeDomains() {
    #expect(YouTubeLink.videoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=2") == "dQw4w9WgXcQ")
    #expect(YouTubeLink.videoID("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    #expect(YouTubeLink.videoID("https://youtube.com.evil.invalid/watch?v=dQw4w9WgXcQ") == nil)
    #expect(YouTubeLink.videoID("https://youtube.com/playlist?list=abc") == nil)
    #expect(YouTubeLink.videoID("javascript:alert(1)") == nil)
  }

  @Test func previewMetadataRoundTripsIncludingHistoricalContext() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EchoLab-test-\(UUID().uuidString)")
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
      "EchoLab-test-\(UUID().uuidString)")
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
