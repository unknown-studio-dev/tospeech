import CryptoKit
import Foundation

struct BundledImportToolchain: Sendable {
  struct Tools: Sendable {
    let ytDLP: URL
    let ffmpeg: URL
    let ffprobe: URL
    let qjs: URL
  }


  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  func resolve() throws -> Tools {
    guard let resources = bundle.resourceURL else { throw BundledImportToolchainError.missingResources }
    let manifestURL = resources.appendingPathComponent("Toolchain.runtime.json")
    guard let manifestData = try? Data(contentsOf: manifestURL),
      let expected = try? JSONDecoder().decode([String: String].self, from: manifestData)
    else { throw BundledImportToolchainError.missingRuntimeManifest }
    let directory = resources.appendingPathComponent("Tools", isDirectory: true)
    return Tools(
      ytDLP: try validate("yt-dlp", at: directory.appendingPathComponent("yt-dlp/yt-dlp_macos"), expected: expected),
      ffmpeg: try validate("ffmpeg", at: directory.appendingPathComponent("ffmpeg"), expected: expected),
      ffprobe: try validate("ffprobe", at: directory.appendingPathComponent("ffprobe"), expected: expected),
      qjs: try validate("qjs", at: directory.appendingPathComponent("qjs"), expected: expected))
  }

  private func validate(_ name: String, at url: URL, expected: [String: String]) throws -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      throw BundledImportToolchainError.missing(name)
    }
    guard fileManager.isExecutableFile(atPath: url.path) else {
      throw BundledImportToolchainError.notExecutable(name)
    }
    let bytes: Data
    do { bytes = try Data(contentsOf: url, options: .mappedIfSafe) }
    catch { throw BundledImportToolchainError.unreadable(name) }
    guard Self.containsArm64MachO(bytes) else {
      throw BundledImportToolchainError.notArm64(name)
    }
    let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard checksum == expected[name] else {
      throw BundledImportToolchainError.checksumMismatch(name)
    }
    return url
  }


  private static func containsArm64MachO(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(4_096))
    guard bytes.count >= 8 else { return false }
    let arm64: [UInt8] = [0x01, 0x00, 0x00, 0x0c]
    if Array(bytes[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe] {
      return Array(bytes[4..<8]) == [0x0c, 0x00, 0x00, 0x01]
    }
    let magic = Array(bytes[0..<4])
    let entrySize: Int
    if magic == [0xca, 0xfe, 0xba, 0xbe] { entrySize = 20 }
    else if magic == [0xca, 0xfe, 0xba, 0xbf] { entrySize = 32 }
    else { return false }
    let count = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
    guard count > 0, bytes.count >= 8 + count * entrySize else { return false }
    return (0..<count).contains { index in
      let start = 8 + index * entrySize
      return Array(bytes[start..<(start + 4)]) == arm64
    }
  }
}

enum BundledImportToolchainError: Error, Equatable, LocalizedError, Sendable {
  case missingResources
  case missing(String)
  case missingRuntimeManifest
  case unreadable(String)
  case notExecutable(String)
  case notArm64(String)
  case checksumMismatch(String)

  var errorDescription: String? {
    switch self {
    case .missingResources: "The app bundle has no resources directory."
    case .missingRuntimeManifest: "The bundled import integrity manifest is missing or invalid."
    case .missing(let tool): "Required import tool is missing: \(tool)."
    case .unreadable(let tool): "Required import tool cannot be read: \(tool)."
    case .notExecutable(let tool): "Required import tool is not executable: \(tool)."
    case .notArm64(let tool): "Required import tool is not an arm64 Mach-O: \(tool)."
    case .checksumMismatch(let tool): "Required import tool failed integrity validation: \(tool)."
    }
  }
}
