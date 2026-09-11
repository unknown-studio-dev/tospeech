import Foundation
import Testing

@testable import EchoLab

@Suite(.serialized)
struct WhisperInstallOrchestrationTests {
  private actor ProgressCollector {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
  }

  private func makeDatabase() throws -> (ProductionDatabase, BackendPaths, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WhisperInstall-\(UUID().uuidString)", isDirectory: true)
    let paths = BackendPaths(root: root)
    let db = try ProductionDatabase(url: paths.database)
    return (db, paths, root)
  }

  @Test func successfulInstallEndsInstalledAndForwardsProgress() async throws {
    let (db, paths, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriber = WhisperCaptionTranscriber(
      database: db, paths: paths,
      downloader: { _, progress in
        progress.report(0.5)
        progress.report(1.0)
        return "Packages/small.en"
      })

    try await transcriber.install(.small)

    let releases = try await db.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    #expect(releases.count == 1)
    #expect(releases[0].version == "small.en")
    #expect(releases[0].status == "installed")
    #expect(releases[0].relativePath == "Packages/small.en")
  }

  @Test func failedDownloadRecordsFailedStatusAndThrows() async throws {
    let (db, paths, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriber = WhisperCaptionTranscriber(
      database: db, paths: paths,
      downloader: { _, _ in throw WhisperTranscriberError.downloadFailed("network") })

    await #expect(throws: WhisperTranscriberError.self) {
      try await transcriber.install(.small)
    }
    let releases = try await db.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    #expect(releases[0].status == "failed")
  }

  @Test func removeResetsInstalledModelToNotInstalled() async throws {
    let (db, paths, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriber = WhisperCaptionTranscriber(
      database: db, paths: paths,
      downloader: { _, _ in "Packages/small.en" })
    try await transcriber.install(.small)
    #expect(try await db.engineReleases(engineKey: WhisperModelCatalog.engineKey)[0].status == "installed")

    try await transcriber.remove(.small)
    let releases = try await db.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    #expect(releases.count == 1)
    #expect(releases[0].status == "not_installed")
    #expect(releases[0].relativePath == nil)
  }

  @Test func retryAfterFailureReachesInstalled() async throws {
    let (db, paths, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let failing = WhisperCaptionTranscriber(
      database: db, paths: paths,
      downloader: { _, _ in throw WhisperTranscriberError.downloadFailed("network") })
    _ = try? await failing.install(.small)

    let succeeding = WhisperCaptionTranscriber(
      database: db, paths: paths,
      downloader: { _, _ in "Packages/small.en" })
    try await succeeding.install(.small)

    let releases = try await db.engineReleases(engineKey: WhisperModelCatalog.engineKey)
    #expect(releases.count == 1)
    #expect(releases[0].status == "installed")
  }
}
