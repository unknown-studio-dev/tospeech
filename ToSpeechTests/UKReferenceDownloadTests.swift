import Foundation
import Testing
@testable import ToSpeech

/// Release bundles ship the UK package without `pytorch_model.bin`; `install` downloads the
/// upstream checkpoint and verifies it against `checksums.json`. A file URL stands in for
/// Hugging Face so the path runs offline against the Debug bundle's copy.
private final class UKDownloadFixtureLocator {}

@Suite struct UKReferenceDownloadTests {
  private func releaseBundle(root: URL) throws -> (bundled: URL, weights: URL) {
    let fm = FileManager.default
    let source = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    let bundled = root.appendingPathComponent("bundle/UKReference")
    try fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: source, to: bundled)
    try fm.removeItem(at: bundled.appendingPathComponent(UKReferencePackage.weights))
    return (bundled, source.appendingPathComponent(UKReferencePackage.weights))
  }

  @Test func installsCheckpointFromUpstreamWhenBundleLacksIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UKDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let (bundled, weights) = try releaseBundle(root: root)
    let package = UKReferencePackage(paths: paths, bundled: bundled, weightsSource: weights)
    #expect(await package.installed() == false)
    try await package.install()
    #expect(await package.installed())
    let installed = try await package.validate()
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(UKReferencePackage.weights).path))
    // The graph must resolve its external weights from the installed directory and run.
    let source = try #require(Bundle(for: UKDownloadFixtureLocator.self).url(forResource: "harmonic-120", withExtension: "wav"))
    let output = try UKReferenceAdapter.encoderFixture(source, directory: installed)
    #expect(output.frames > 0)
    #expect(output.hidden.allSatisfy { $0.isFinite } && output.logp.allSatisfy { $0.isFinite })
  }

  @Test func rejectsCheckpointWhoseHashDiffersFromManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UKDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let (bundled, _) = try releaseBundle(root: root)
    let forged = root.appendingPathComponent("forged.bin")
    try Data("not the checkpoint".utf8).write(to: forged)
    let package = UKReferencePackage(paths: paths, bundled: bundled, weightsSource: forged)
    do {
      try await package.install()
      Issue.record("A checkpoint whose hash differs from the pinned manifest must never install")
    } catch BuddyError.checksum { } catch { Issue.record("Wrong error: \(error)") }
    #expect(await package.installed() == false)
  }

  @Test func olderInstallationMarkerCountsAsNotInstalled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UKDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let package = UKReferencePackage(paths: paths, bundled: nil)
    let directory = await package.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("UK Reference · older layout".utf8).write(to: directory.appendingPathComponent("verified.txt"))
    #expect(await package.installed() == false)
  }
}
