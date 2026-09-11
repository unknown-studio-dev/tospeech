import Foundation
import Testing

@testable import EchoLab

@Suite(.serialized)
struct EngineInstallationPersistenceTests {
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "EngineInstall-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeDatabase() throws -> (ProductionDatabase, URL) {
    let root = temporaryRoot()
    let url = root.appendingPathComponent("echolab.sqlite3")
    return (try ProductionDatabase(url: url), root)
  }

  @Test func registerIsIdempotentPerVersion() async throws {
    let (db, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = WhisperModelCatalog.engineKey
    let first = try await db.registerEngineRelease(
      engineKey: key, version: "small.en", capabilityJSON: "{}")
    let second = try await db.registerEngineRelease(
      engineKey: key, version: "small.en", capabilityJSON: "{}")
    #expect(first == second)
    let releases = try await db.engineReleases(engineKey: key)
    #expect(releases.count == 1)
    #expect(releases[0].version == "small.en")
    #expect(releases[0].status == "not_installed")
    #expect(releases[0].relativePath == nil)
  }

  @Test func installationStatusTransitions() async throws {
    let (db, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = WhisperModelCatalog.engineKey
    let id = try await db.registerEngineRelease(
      engineKey: key, version: "small.en", capabilityJSON: "{}")

    try await db.setEngineInstallationStatus(releaseID: id, status: "downloading")
    #expect(try await db.engineReleases(engineKey: key)[0].status == "downloading")

    try await db.setEngineInstallationStatus(
      releaseID: id, status: "installed", relativePath: "Packages/small.en")
    let installed = try await db.engineReleases(engineKey: key)[0]
    #expect(installed.status == "installed")
    #expect(installed.relativePath == "Packages/small.en")

    try await db.setEngineInstallationStatus(
      releaseID: id, status: "failed", errorJSON: "{\"reason\":\"network\"}")
    #expect(try await db.engineReleases(engineKey: key)[0].status == "failed")
  }

  @Test func multipleVariantsCoexistIndependently() async throws {
    let (db, root) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = WhisperModelCatalog.engineKey
    let tiny = try await db.registerEngineRelease(
      engineKey: key, version: "tiny.en", capabilityJSON: "{}")
    _ = try await db.registerEngineRelease(
      engineKey: key, version: "small.en", capabilityJSON: "{}")
    try await db.setEngineInstallationStatus(
      releaseID: tiny, status: "installed", relativePath: "Packages/tiny.en")

    let releases = try await db.engineReleases(engineKey: key)
    #expect(releases.map(\.version) == ["small.en", "tiny.en"])
    let tinyRow = releases.first { $0.version == "tiny.en" }
    let smallRow = releases.first { $0.version == "small.en" }
    #expect(tinyRow?.status == "installed")
    #expect(smallRow?.status == "not_installed")
  }
}
