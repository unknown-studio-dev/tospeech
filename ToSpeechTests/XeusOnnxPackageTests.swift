import Foundation
import Testing
@testable import ToSpeech

/// Install/verify tests for the native ONNX package (`PhoneticXeusPackage`, repurposed from the old
/// Python runtime). Mirrors `AlignmentPackageTests`: the small graph + resources ship bundled, the
/// heavy `xeus.onnx.data` downloads from the release and is verified against the pinned sha256. A
/// file URL stands in for the release download so the reject/marker paths run offline.
@Suite struct XeusOnnxPackageTests {
  /// A synthetic bundle with the small graph + vocab present but no `xeus.onnx.data` — enough for
  /// `install()` to reach the download+verify step.
  private func syntheticBundle(root: URL) throws -> URL {
    let fm = FileManager.default
    let bundled = root.appendingPathComponent("bundle/PhoneticXeus")
    try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
    try Data("onnx-graph-placeholder".utf8).write(to: bundled.appendingPathComponent(PhoneticXeusPackage.graphName))
    try Data(#"{"<blank>":0}"#.utf8).write(to: bundled.appendingPathComponent(PhoneticXeusPackage.vocabName))
    return bundled
  }

  @Test func rejectsExternalDataWhoseHashDiffersFromManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XeusOnnxTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let bundled = try syntheticBundle(root: root)
    let forged = root.appendingPathComponent("forged.onnx.data")
    try Data("not the real external-data weights".utf8).write(to: forged)
    let package = PhoneticXeusPackage(paths: paths, bundled: bundled, weightsSource: forged)
    do {
      try await package.install()
      Issue.record("External data whose hash differs from the pinned manifest must never install")
    } catch BuddyError.checksum { } catch { Issue.record("Wrong error: \(error)") }
    #expect(await package.installed() == false)
  }

  @Test func olderPythonRuntimeMarkerCountsAsNotInstalled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XeusOnnxTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let bundled = try syntheticBundle(root: root)
    let package = PhoneticXeusPackage(paths: paths, bundled: bundled)
    let directory = await package.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A verified.txt from the old Python-runtime layout must not read as installed.
    try Data("PhoneticXeus weights · 8d83dee94817a07dc150f87d08f7e0ee01bdb66d · <safetensors-hash>".utf8)
      .write(to: directory.appendingPathComponent("verified.txt"))
    #expect(await package.installed() == false)
  }

  @Test func missingBundledGraphFailsInstall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XeusOnnxTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root.appendingPathComponent("container"))
    try paths.prepare()
    let package = PhoneticXeusPackage(paths: paths, bundled: nil)
    do {
      try await package.install()
      Issue.record("Install without a bundled graph must fail")
    } catch PhoneticXeusError.runtimeMissing { } catch { Issue.record("Wrong error: \(error)") }
    #expect(await package.installed() == false)
  }

  /// The pinned identity constants that the assessment service and `convert` key jobs by must stay
  /// aligned with the ported runtime revision/policies.
  @Test func identityConstantsMatchPortedRuntime() {
    #expect(PhoneticXeusPackage.revision == XeusRuntime.revision)
    #expect(PhoneticXeusPackage.evidencePolicy == XeusAssess.policy)
    #expect(PhoneticXeusPackage.mappingPolicy == XeusInventory.mapping)
    #expect(PhoneticXeusPackage.provenance.hasPrefix("PhoneticXeus · "))
  }
}
