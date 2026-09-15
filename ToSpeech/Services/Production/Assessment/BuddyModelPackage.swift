import CryptoKit
import Foundation

actor BuddyModelPackage {
  static let revision = "bbc37113ff91fdda6b2b1a79f44fbb78bdc4c588"
  static let modelHash = "616794bd723a99e00ed9d1ce5360e7fad9bf66a539ff2d843d4a58c0e5125e70"
  static let vocabularyHash = "f5481b0a50d50e024233be364e5518270ccc5447dea9e0fd01525f0478cab458"
  static let provenance = "Buddy en/v1 · \(revision) · \(modelHash) · ONNX Runtime 1.24.2 · ipa-evidence-v2-reference-gate"
  let directory: URL
  private var installing = false
  init(paths: BackendPaths) { directory = paths.packages.appendingPathComponent("Buddy/en-v1") }

  func installed() -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent("verified.json").path)
      && FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.int8.onnx").path)
  }

  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    guard try Self.checksum(directory.appendingPathComponent("model.int8.onnx")) == Self.modelHash,
      try Self.checksum(directory.appendingPathComponent("vocab.json")) == Self.vocabularyHash else {
      throw BuddyError.checksum
    }
    return directory
  }

  func install() async throws {
    guard !installing else { throw BuddyError.busy }
    installing = true
    defer { installing = false }
    let fm = FileManager.default
    let parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    // Recover only this installer's UUID staging directories after an interrupted download.
    for old in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
      where UUID(uuidString: old.lastPathComponent) != nil {
      try fm.removeItem(at: old)
    }
    let staging = parent.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    for name in ["model.int8.onnx", "vocab.json", "LICENSE", "NOTICE"] {
      try Task.checkCancellation()
      let path = ["LICENSE", "NOTICE"].contains(name) ? name : "en/v1/\(name)"
      let url = URL(string: "https://huggingface.co/asingingbird/buddy-pronunciation-onnx/resolve/\(Self.revision)/\(path)")!
      let (temporary, response) = try await URLSession.shared.download(from: url)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw BuddyError.download }
      try fm.moveItem(at: temporary, to: staging.appendingPathComponent(name))
    }
    guard try Self.checksum(staging.appendingPathComponent("model.int8.onnx")) == Self.modelHash,
      try Self.checksum(staging.appendingPathComponent("vocab.json")) == Self.vocabularyHash else { throw BuddyError.checksum }
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: staging.appendingPathComponent("vocab.json")))
    guard vocab["[PAD]"] == 124, vocab[" "] == 0, vocab.count == 125 else { throw BuddyError.invalidOutput }
    try Data(Self.provenance.utf8).write(to: staging.appendingPathComponent("verified.json"), options: .atomic)
    try Task.checkCancellation()
    if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: directory) }
  }

  func remove() throws {
    guard !installing else { throw BuddyError.busy }
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  nonisolated static func checksum(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

enum BuddyError: Error, LocalizedError {
  case modelMissing, checksum, busy, download, invalidOutput, invalidAudio, tooLong, noSpeech
  var errorDescription: String? {
    switch self {
    case .modelMissing: "assessment.error.model_missing"
    case .checksum: "assessment.error.checksum"
    case .busy: "assessment.error.busy"
    case .download: "assessment.error.download"
    case .invalidOutput: "assessment.error.output"
    case .invalidAudio: "assessment.error.audio"
    case .tooLong: "assessment.error.too_long"
    case .noSpeech: "assessment.error.no_speech"
    }
  }
}
