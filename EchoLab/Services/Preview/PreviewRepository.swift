import Foundation

struct PreviewRepository {
  var url: URL?
  static var local: Self {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return Self(url: root.appendingPathComponent("EchoLab/NativePreview/snapshot-v1.json"))
  }
  static var memory: Self { Self(url: nil) }
  func load() throws -> PreviewSnapshot? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    let snapshot = try JSONDecoder().decode(PreviewSnapshot.self, from: Data(contentsOf: url))
    guard snapshot.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
    return snapshot
  }
  func save(_ snapshot: PreviewSnapshot) throws {
    guard let url else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
  }
}
