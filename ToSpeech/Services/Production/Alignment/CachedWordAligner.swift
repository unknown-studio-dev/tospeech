import CryptoKit
import Foundation
import OSLog

/// Import workspace cache; retries reuse acoustic work only for the same audio,
/// transcript anchors and model/policy. Workspace deletion also removes this text.
struct CachedWordAligner: WordAlignmentAdapter {
  let underlying: any WordAlignmentAdapter
  let directory: URL
  let version: String

  func align(_ request: WordAlignmentRequest) async throws -> WordAlignmentResult {
    try Task.checkCancellation()
    var hash = SHA256()
    let file = try FileHandle(forReadingFrom: request.audioURL)
    defer { try? file.close() }
    while let data = try file.read(upToCount: 65536), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    hash.update(data: try encoder.encode(request.words))
    hash.update(data: try encoder.encode(request.sentenceStartIndices.sorted()))
    hash.update(data: Data(version.utf8))
    let name = hash.finalize().map { String(format: "%02x", $0) }.joined() + ".json"
    let url = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let result = try JSONDecoder().decode(WordAlignmentResult.self, from: Data(contentsOf: url))
        guard result.words.count == request.words.count,
          zip(result.words, request.words).allSatisfy({ $0 == nil || $0?.text == $1.text })
        else { throw WordAlignmentError.invalidOutput }
        return result
      } catch {
        Logger(subsystem: "com.unknownstudio.tospeech", category: "Alignment").warning("Alignment cache rejected: \(error)")
      }
    }
    let result = try await underlying.align(request)
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(result).write(to: url, options: .atomic)
    return result
  }
}
