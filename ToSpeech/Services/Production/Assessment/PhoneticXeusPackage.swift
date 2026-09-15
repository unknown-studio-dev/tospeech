import Foundation

actor PhoneticXeusPackage {
  static let revision = "8d83dee94817a07dc150f87d08f7e0ee01bdb66d"
  static let weightHash = "ad58bf20a60e9d0380327bd8b2d0e8e90a9b8de2adccbfb479f9b21ea85eda18"
  static let runtimeHash = "4e479a3d14fbdad167e0077004200228103faf5b2cbdb5e6e265829690f0343b"
  static let evidencePolicy = "xeus-uk-ctc-evidence-v5-units"
  static let mappingPolicy = "xeus-uk-inventory-v3"
  static let installationIdentity = "PhoneticXeus weights · \(revision) · \(weightHash)"
  static let provenance = "PhoneticXeus · UK Experimental · \(revision) · \(weightHash) · torch-2.10.0-cpu-fp32 · \(evidencePolicy) · \(mappingPolicy) · \(UKPhoneInventory.parsingPolicy) · runtime \(runtimeHash)"
  /// A bundled helper update does not invalidate unchanged checkpoint bytes.
  /// `validate` still checks the weight checksum before every assessment; the 2,3 GB file is hashed
  /// once per file version and re-hashed as soon as `stat` changes (`ModelChecksumCache`).
  static func acceptsInstallationMarker(_ marker: String) -> Bool {
    marker == installationIdentity || marker.hasPrefix("PhoneticXeus · UK Experimental · \(revision) · \(weightHash) · ")
  }
  let directory: URL
  private let bundled: URL?
  private var installing = false
  /// Hashing `model.safetensors` (2,3 GB) per job cost ≈1,5 s of every assessment; this package is
  /// the only owner of that file, so it is the only thing that has to remember the hash.
  private let checksums = ModelChecksumCache()
  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("PhoneticXeus")) {
    directory = paths.packages.appendingPathComponent("PhoneticXeus/\(Self.revision)")
    self.bundled = bundled
  }
  func helper() throws -> URL {
    guard let bundled else { throw PhoneticXeusError.runtimeMissing }
    guard try BuddyModelPackage.checksum(bundled.appendingPathComponent("checksums.json")) == Self.runtimeHash else { throw BuddyError.checksum }
    let executable = bundled.appendingPathComponent("xeus-helper")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PhoneticXeusError.runtimeMissing }
    return executable
  }
  func installed() -> Bool {
    guard (try? helper()) != nil,
      let marker = try? String(contentsOf: directory.appendingPathComponent("verified.txt"), encoding: .utf8),
      Self.acceptsInstallationMarker(marker) else { return false }
    return FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path)
  }
  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    guard try checksums.hash(directory.appendingPathComponent("model.safetensors")) == Self.weightHash else { throw BuddyError.checksum }
    return directory
  }
  func install() async throws {
    guard !installing else { throw BuddyError.busy }
    _ = try helper()
    installing = true; defer { installing = false }
    let fm = FileManager.default, parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://huggingface.co/changelinglab/PhoneticXeus/resolve/\(Self.revision)/model.safetensors")!
    let (temporary, response) = try await session.download(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BuddyError.download }
    let weights = staging.appendingPathComponent("model.safetensors")
    try fm.moveItem(at: temporary, to: weights)
    try Task.checkCancellation()
    guard try BuddyModelPackage.checksum(weights) == Self.weightHash else { throw BuddyError.checksum }
    try Data(Self.installationIdentity.utf8).write(to: staging.appendingPathComponent("verified.txt"), options: .atomic)
    try Task.checkCancellation()
    if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: directory) }
  }
  func remove() throws {
    guard !installing else { throw BuddyError.busy }
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }
}

enum PhoneticXeusError: Error, LocalizedError {
  case runtimeMissing, invalidEvidence, target(String)
  var errorDescription: String? {
    switch self {
    case .runtimeMissing: "assessment.xeus.runtime_missing"
    case .invalidEvidence: "assessment.xeus.invalid_evidence"
    case .target(let word): "PhoneticXeus: unsupported UK IPA in \(word)"
    }
  }
}
