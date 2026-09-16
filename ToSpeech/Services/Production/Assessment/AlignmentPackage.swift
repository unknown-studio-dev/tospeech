import Foundation

/// Word alignment is used by every practice session regardless of reference accent, so this
/// package is downloaded at onboarding alongside Parakeet, never gated on an accent choice.
actor AlignmentPackage {
  static let provenance = "EnglishAlignment · facebook/wav2vec2-base-960h 22aad52d435eb6dbaf354bdad9b0da84ce7d6156 · coremltools 8.3.0 · package " + manifestHash
  // Pinned only by scripts/alignment/freeze_package.py after the compiled graph is reviewed.
  static let manifestHash = "8bbc298e838ec4870c7ff95c6f32a8d341fd0ea10c6b5d6bcd34baf82e4938b4"
  let directory: URL
  private let bundled: URL?
  private let checksums = ModelChecksumCache()
  /// The compiled Core ML graph's weights are a 188 MB external file inside
  /// `EnglishAlignment.mlmodelc/weights/`. Release bundles leave it out; the app downloads it
  /// from the GitHub release asset instead. Debug bundles it so development and tests stay
  /// offline (`scripts/xcode/stage-alignment.sh`).
  static let weights = "EnglishAlignment.mlmodelc/weights/weight.bin"
  static let weightsURL = URL(string: "https://github.com/unknown-studio-dev/tospeech/releases/latest/download/EnglishAlignment-weight.bin")!
  private let weightsSource: URL
  /// A pure function of `paths`, not actor state, so callers that need the container path
  /// before the app finishes launching (word alignment's constructor, developer tooling) never
  /// have to `await` this actor just to compute it.
  nonisolated static func directory(paths: BackendPaths) -> URL {
    paths.packages.appendingPathComponent("Alignment/v1")
  }
  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("Alignment"),
    weightsSource: URL = weightsURL) {
    directory = Self.directory(paths: paths)
    self.bundled = bundled
    self.weightsSource = weightsSource
  }
  func installed() -> Bool {
    (try? String(contentsOf: directory.appendingPathComponent("verified.txt"), encoding: .utf8)) == Self.provenance
  }
  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    try Self.verify(directory, cache: checksums)
    return directory
  }
  func install() async throws {
    guard let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("checksums.json").path)
    else { throw BuddyError.modelMissing }
    let fm = FileManager.default, parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: bundled, to: staging)
    let weights = staging.appendingPathComponent(Self.weights)
    if !fm.fileExists(atPath: weights.path) {
      try Task.checkCancellation()
      // Release bundles carry the rest of EnglishAlignment.mlmodelc but not this file, so the
      // weights/ directory the download lands in may not exist yet.
      try fm.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 3600
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let (temporary, response) = try await session.download(from: weightsSource)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw BuddyError.download }
      try fm.moveItem(at: temporary, to: weights)
    }
    try Self.verify(staging)
    try Task.checkCancellation()
    try Data(Self.provenance.utf8).write(to: staging.appendingPathComponent("verified.txt"), options: .atomic)
    if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: directory) }
  }
  func remove() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }
  /// Without a `cache` every byte is read again — what a fresh install wants. `validate()` passes
  /// this package's cache so a repeat check of unchanged files costs a `stat` each.
  static func verify(_ directory: URL, cache: ModelChecksumCache? = nil) throws {
    func checksum(_ url: URL) throws -> String { try cache?.hash(url) ?? BuddyModelPackage.checksum(url) }
    let manifestURL = directory.appendingPathComponent("checksums.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw BuddyError.modelMissing }
    guard try checksum(manifestURL) == manifestHash else { throw BuddyError.checksum }
    let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
    for name in [weights, "EnglishAlignment.mlmodelc/model.mil", "EnglishAlignment.mlmodelc/metadata.json",
      "EnglishAlignment.mlmodelc/coremldata.bin", "EnglishAlignment.mlmodelc/analytics/coremldata.bin",
      "vocab.json", "provenance.json"] {
      guard hashes[name] != nil else { throw BuddyError.checksum }
    }
    for (name, hash) in hashes {
      guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
        try checksum(directory.appendingPathComponent(name)) == hash
      else { throw BuddyError.checksum }
    }
  }
}
