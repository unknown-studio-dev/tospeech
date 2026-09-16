import Foundation

/// The native ONNX package for the `.phoneticXeus` UK scorer. Replaces the old ~355 MB Python/torch
/// runtime + 2.3 GB safetensors download: the small `xeus.onnx` graph (+ `ipa_vocab.json`,
/// `uk-contrast-head.json`, `thresholds.json`) ships in the signed bundle, and the heavy
/// `xeus.onnx.data` (external-data weights) downloads on demand from the GitHub release and is
/// verified against the pinned sha256, then installed into the container (`Packages/PhoneticXeus/<rev>`).
///
/// The type keeps its name (and its identity statics `revision`/`evidencePolicy`/`mappingPolicy`/
/// `provenance`) so the assessment service, onboarding and Settings that key jobs by provenance are
/// unchanged; only its contents moved from a Python helper to an ONNX download.
actor PhoneticXeusPackage {
  static let revision = "8d83dee94817a07dc150f87d08f7e0ee01bdb66d"
  /// sha256 of the small graph `xeus.onnx` and its external-data file `xeus.onnx.data`
  /// (`scripts/assessment/phoneticxeus/onnx-manifest.sha256`).
  static let graphHash = "2e9df8e0accbaafff4825df5ece6b8a8131684ee9ee8fecbb6f212fd322be013"
  static let dataHash = "2f3b2d105220433865cf430cc9f069a183760f528c63daaa677ef52d24a4068e"
  static let evidencePolicy = "xeus-uk-decision-v6-word-gated"
  static let mappingPolicy = "xeus-uk-inventory-v4"
  static let calibration = "native-zero-false-sai-v1"
  static let graphName = "xeus.onnx"
  static let dataName = "xeus.onnx.data"
  static let weightsURL = URL(string: "https://github.com/unknown-studio-dev/tospeech/releases/latest/download/xeus.onnx.data")!

  static let installationIdentity = "PhoneticXeus ONNX · \(revision) · \(graphHash) · \(dataHash)"
  static let provenance = "PhoneticXeus · UK Experimental · \(revision) · \(graphHash) · onnxruntime-fp32 · \(evidencePolicy) · \(mappingPolicy) · \(UKPhoneInventory.parsingPolicy) · data \(dataHash) · \(calibration)"

  /// A marker from an older layout (Python runtime + safetensors) means "not installed": onboarding
  /// and Settings then offer the ONNX download instead of failing every assessment.
  static func acceptsInstallationMarker(_ marker: String) -> Bool { marker == installationIdentity }

  let directory: URL
  private let bundled: URL?
  private let weightsSource: URL
  private var installing = false
  /// Hashing `xeus.onnx.data` (2.3 GB) per job is expensive; this package is the only owner of that
  /// file, so it caches the hash and re-hashes only when `stat` says the file changed.
  private let checksums = ModelChecksumCache()

  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("PhoneticXeus"),
    weightsSource: URL = weightsURL) {
    directory = paths.packages.appendingPathComponent("PhoneticXeus/\(Self.revision)")
    self.bundled = bundled
    self.weightsSource = weightsSource
  }

  /// The small graph + resources ship in the bundle; a build without them hides the engine in
  /// Settings (mirrors the old `runtimeAvailable`).
  func runtimeAvailable() -> Bool {
    guard let bundled else { return false }
    let fm = FileManager.default
    return fm.fileExists(atPath: bundled.appendingPathComponent(Self.graphName).path)
      && fm.fileExists(atPath: bundled.appendingPathComponent(Self.vocabName).path)
  }

  func installed() -> Bool {
    guard runtimeAvailable(),
      let marker = try? String(contentsOf: directory.appendingPathComponent("verified.txt"), encoding: .utf8),
      Self.acceptsInstallationMarker(marker) else { return false }
    let fm = FileManager.default
    return fm.fileExists(atPath: directory.appendingPathComponent(Self.graphName).path)
      && fm.fileExists(atPath: directory.appendingPathComponent(Self.dataName).path)
  }

  /// Validates the installed package before every assessment and returns its directory (containing
  /// `xeus.onnx`, `xeus.onnx.data`, `ipa_vocab.json`, `uk-contrast-head.json`).
  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    guard try checksums.hash(directory.appendingPathComponent(Self.dataName)) == Self.dataHash,
      try BuddyModelPackage.checksum(directory.appendingPathComponent(Self.graphName)) == Self.graphHash
    else { throw BuddyError.checksum }
    return directory
  }

  func install() async throws {
    guard !installing else { throw BuddyError.busy }
    guard let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent(Self.graphName).path)
    else { throw PhoneticXeusError.runtimeMissing }
    installing = true; defer { installing = false }
    let fm = FileManager.default, parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: staging) }
    // Copy the bundled small graph + resources, then fetch the heavy external-data file.
    try fm.copyItem(at: bundled, to: staging)
    let data = staging.appendingPathComponent(Self.dataName)
    if !fm.fileExists(atPath: data.path) {
      try Task.checkCancellation()
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
      let session = URLSession(configuration: config)
      defer { session.invalidateAndCancel() }
      let (temporary, response) = try await session.download(from: weightsSource)
      // Only a non-200 HTTP response is a download failure; a file:// URL (offline tests) has no
      // HTTPURLResponse and is allowed through, mirroring UKReferencePackage/AlignmentPackage.
      if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw BuddyError.download }
      try fm.moveItem(at: temporary, to: data)
    }
    try Task.checkCancellation()
    guard try BuddyModelPackage.checksum(data) == Self.dataHash,
      try BuddyModelPackage.checksum(staging.appendingPathComponent(Self.graphName)) == Self.graphHash
    else { throw BuddyError.checksum }
    try Data(Self.installationIdentity.utf8).write(to: staging.appendingPathComponent("verified.txt"), options: .atomic)
    try Task.checkCancellation()
    if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: directory) }
  }

  func remove() throws {
    guard !installing else { throw BuddyError.busy }
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  static let vocabName = "ipa_vocab.json"
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
