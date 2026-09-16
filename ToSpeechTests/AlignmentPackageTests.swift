import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

/// Release bundles ship the Alignment package without `weight.bin`; `install` downloads it
/// from the GitHub release asset and verifies it against `checksums.json`. A file URL stands
/// in for the release download so the path runs offline against the Debug bundle's copy —
/// mirrors `UKReferenceDownloadTests`.
private final class AlignmentDownloadFixtureLocator {}

@Suite struct AlignmentPackageTests {
  private func releaseBundle(root: URL) throws -> (bundled: URL, weights: URL) {
    let fm = FileManager.default
    let source = try #require(Bundle.main.resourceURL).appendingPathComponent("Alignment")
    let bundled = root.appendingPathComponent("bundle/Alignment")
    try fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: source, to: bundled)
    try fm.removeItem(at: bundled.appendingPathComponent(AlignmentPackage.weights))
    return (bundled, source.appendingPathComponent(AlignmentPackage.weights))
  }

  @Test func installsWeightsFromUpstreamWhenBundleLacksThemAndNestsThemUnderWeightsDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let (bundled, weights) = try releaseBundle(root: root)
    let package = AlignmentPackage(paths: paths, bundled: bundled, weightsSource: weights)
    #expect(await package.installed() == false)
    try await package.install()
    #expect(await package.installed())
    let installed = try await package.validate()
    // `.path` compares the two directories' identity; raw `URL ==` is sensitive to whether
    // `appendingPathComponent` observed the directory on disk yet when it decided to append a
    // trailing slash, which install() itself never depends on (`directory` is a stored `let`).
    #expect(installed.path == AlignmentPackage.directory(paths: paths).path)
    let weightsURL = installed.appendingPathComponent(AlignmentPackage.weights)
    #expect(FileManager.default.fileExists(atPath: weightsURL.path))
    #expect(weightsURL.lastPathComponent == "weight.bin")
    #expect(weightsURL.deletingLastPathComponent().lastPathComponent == "weights")
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("EnglishAlignment.mlmodelc").path))
  }

  @Test func rejectsWeightsWhoseHashDiffersFromManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let (bundled, _) = try releaseBundle(root: root)
    let forged = root.appendingPathComponent("forged.bin")
    try Data("not the compiled weights".utf8).write(to: forged)
    let package = AlignmentPackage(paths: paths, bundled: bundled, weightsSource: forged)
    do {
      try await package.install()
      Issue.record("Weights whose hash differs from the pinned manifest must never install")
    } catch BuddyError.checksum { } catch { Issue.record("Wrong error: \(error)") }
    #expect(await package.installed() == false)
  }

  @Test func olderInstallationMarkerCountsAsNotInstalled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let package = AlignmentPackage(paths: paths, bundled: nil)
    let directory = await package.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("EnglishAlignment · older layout".utf8).write(to: directory.appendingPathComponent("verified.txt"))
    #expect(await package.installed() == false)
  }

  @Test func missingBundleFailsInstallWithoutTouchingContainer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentDownloadTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let package = AlignmentPackage(paths: paths, bundled: nil)
    do {
      try await package.install()
      Issue.record("Install without a bundled package must fail, not silently no-op")
    } catch BuddyError.modelMissing { } catch { Issue.record("Wrong error: \(error)") }
    #expect(await package.installed() == false)
  }
}

/// `CoreMLWordAligner` is constructed with the container directory it should load from — never
/// `Bundle.main` directly in production, since a Release bundle excludes `weight.bin` until the
/// package is downloaded. These tests exercise that injected directory end to end.
@Suite struct AlignmentPackageWordAlignerTests {
  private func silentFixture(seconds: Double = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentAlignerFixture-\(UUID()).caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let count = AVAudioFrameCount(16000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    let writer = try AVAudioFile(forWriting: url, settings: format.settings)
    try writer.write(from: buffer)
    return url
  }

  @Test func throwsModelUnavailableWhenContainerIsEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentAlignerEmpty-\(UUID())")
    let aligner = CoreMLWordAligner(directory: directory)
    let request = WordAlignmentRequest(audioURL: try silentFixture(), words: [.init(text: "hi", start: 0.1, end: 0.3)])
    do {
      _ = try await aligner.align(request)
      Issue.record("An uninstalled container must not silently claim alignment succeeded")
    } catch WordAlignmentError.modelUnavailable { } catch { Issue.record("Wrong error: \(error)") }
  }

  @Test func loadsCompiledModelFromInstalledContainerDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentAlignerInstall-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    // Debug bundles ship `weight.bin`, so installing straight from the bundle stays offline.
    let package = AlignmentPackage(paths: paths)
    try await package.install()
    let installed = try await package.validate()
    #expect(installed.path == AlignmentPackage.directory(paths: paths).path)

    let aligner = CoreMLWordAligner(directory: installed)
    let request = WordAlignmentRequest(audioURL: try silentFixture(), words: [.init(text: "hi", start: 0.1, end: 0.3)])
    let result = try await aligner.align(request)
    #expect(result.words.count == 1)
  }
}
