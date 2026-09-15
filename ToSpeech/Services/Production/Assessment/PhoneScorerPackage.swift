import Foundation

actor PhoneScorerPackage {
  static let provenance = "Phone Scorer E16 · 2211f19be4abc6cdfb7908eb9bbb34f9dcccb550 · ead3144c82ab87ad9d6406511c6348a99c944a9f8ac1097756a6a61d78e80338 · ONNX Runtime 1.24.2 · tospeech-phone-onnx-v1"
  static let hashes = [
    "acoustic.onnx": "7af93644de1af1cdc063b5a01fbf5eb03264c04217348710a48fbe7a14a3275d",
    "scorer.onnx": "896373d0422f26cbf2bfdbe677ed565d526858e88676319ba4b826345f269a00"
  ]
  let directory: URL
  private let bundled: URL?
  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("PhoneScorer")) {
    directory = paths.packages.appendingPathComponent("PhoneScorer/e16-v1")
    self.bundled = bundled
  }
  func installed() -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("verified.txt").path) }
  func validate() throws -> URL {
    guard installed() else { throw PhoneScorerError.packageMissing }
    try Self.verify(directory)
    return directory
  }
  func install() throws {
    guard let bundled else { throw PhoneScorerError.packageMissing }
    try Self.verify(bundled)
    let fm = FileManager.default
    let parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: bundled, to: staging)
    try Self.verify(staging)
    try Task.checkCancellation()
    try Data(Self.provenance.utf8).write(to: staging.appendingPathComponent("verified.txt"), options: .atomic)
    if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: directory) }
  }
  func remove() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }
  private static func verify(_ directory: URL) throws {
    for (name, hash) in hashes {
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { throw PhoneScorerError.packageMissing }
      guard try BuddyModelPackage.checksum(url) == hash else { throw BuddyError.checksum }
    }
  }
}
