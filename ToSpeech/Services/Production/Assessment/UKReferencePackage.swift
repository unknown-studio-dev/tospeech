import Foundation

actor UKReferencePackage {
  static let provenance = "UK Reference · XLSR 2c733782da5604684829819a5eb744c193fe9398 · UK heads v1 · SwiftF0 64700fce · ONNX Runtime 1.24.2" + " · " + UKReferenceEvidence.policy + " · " + UKReferenceQuality.policy + " · " + UKVoiceActivity.policy + " · " + UKPhoneInventory.parsingPolicy + " · package " + manifestHash
  // Pinned only by the explicit freeze script after model verification.
  static let manifestHash = "f61721693bbd843a8a771946f361ff1c0a762f859c488951f895ea319f1fc503"
  let directory: URL
  private let bundled: URL?
  /// `verify` hashes every file in `checksums.json`, `pytorch_model.bin` (1,26 GB) included, and
  /// `validate()` runs before every assessment — twice per PhoneticXeus job. This package owns the
  /// installed copy, so it keeps each hash until `stat` says the file changed.
  private let checksums = ModelChecksumCache()
  /// `encoder.onnx` is a 440 KB graph whose initializers point into the upstream checkpoint
  /// (`scripts/assessment/externalize_uk_encoder.py`), so the app downloads the original
  /// `pytorch_model.bin` (1,26 GB) from Hugging Face instead of shipping a converted copy.
  /// Release bundles leave it out; `checksums.json` pins its hash with the rest of the package.
  static let weights = "pytorch_model.bin"
  static let weightsURL = URL(string: "https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/resolve/2c733782da5604684829819a5eb744c193fe9398/pytorch_model.bin")!
  private let weightsSource: URL
  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("UKReference"),
    weightsSource: URL = weightsURL) {
    directory = paths.packages.appendingPathComponent("UKReference/v1")
    self.bundled = bundled
    self.weightsSource = weightsSource
  }
  /// A marker from an older package layout (self-contained `encoder.onnx`) means "not installed":
  /// onboarding and Settings then offer the download instead of failing every assessment.
  func installed() -> Bool {
    (try? String(contentsOf: directory.appendingPathComponent("verified.txt"), encoding: .utf8)) == Self.provenance
  }
  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    try Self.verify(directory, cache: checksums)
    return directory
  }
  /// Executable code stays in the signed app bundle; installed model data stays
  /// in the container. macOS can reject execution from writable package storage.
  /// `espeak-ng` is intentionally not hashed: codesign rewrites it every build, so only
  /// the sealed bundle can vouch for it — the manifest still pins the package identity.
  func helperExecutable() throws -> URL {
    guard let bundled else { throw BuddyError.modelMissing }
    let manifest = bundled.appendingPathComponent("checksums.json")
    guard try BuddyModelPackage.checksum(manifest) == Self.manifestHash else { throw BuddyError.checksum }
    return bundled.appendingPathComponent("espeak-ng")
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
    for name in ["encoder.onnx", weights, "vad.onnx", "vocab.json", "uk-vowels.json", "uk-focus.json", "uk-stress.json", "uk-boundary.json", "pitch.onnx", "espeak-ng-data/en_dict"] {
      guard hashes[name] != nil else { throw BuddyError.checksum }
    }
    for (name, hash) in hashes {
      guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
        try checksum(directory.appendingPathComponent(name)) == hash
      else { throw BuddyError.checksum }
    }
  }
}

struct UKVowelHead: Decodable, Sendable {
  let labels: [String]
  let mean: [Double]
  let scale: [Double]
  let weights: [[Double]]
  let bias: [Double]
  let confidenceFloor: Double
  let policy: String
  typealias Prediction = UKVowelPrediction
  static func load(directory: URL, name: String = "uk-vowels.json") throws -> UKVowelHead {
    let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    guard !model.labels.isEmpty, model.mean.count == model.scale.count,
      model.scale.allSatisfy({ $0.isFinite && $0 > 0 }), model.mean.allSatisfy(\.isFinite),
      model.weights.count == model.bias.count,
      model.weights.allSatisfy({ $0.count == model.mean.count && $0.allSatisfy(\.isFinite) }),
      model.bias.allSatisfy(\.isFinite), model.confidenceFloor.isFinite,
      (0.5...1).contains(model.confidenceFloor),
      model.weights.count == model.labels.count || (model.weights.count == 1 && model.labels.count == 2)
    else { throw BuddyError.invalidOutput }
    return model
  }
  func probabilities(_ values: [Double]) -> [Double]? {
    guard values.count == mean.count, values.allSatisfy(\.isFinite) else { return nil }
    let x = values.indices.map { (values[$0]-mean[$0])/scale[$0] }
    let logits = weights.indices.map { i in zip(weights[i],x).reduce(bias[i]) { $0+$1.0*$1.1 } }
    if logits.count == 1 {
      let p = 1/(1+exp(-logits[0])); return [1-p,p]
    }
    guard let maximum = logits.max() else { return nil }
    let exponentials = logits.map { exp($0-maximum) }, total = exponentials.reduce(0,+)
    return exponentials.map { $0/total }
  }
  func predict(_ values: [Double]) -> Prediction? {
    guard let p = probabilities(values), let best = p.indices.max(by: { p[$0] < p[$1] }) else { return nil }
    return .init(symbol: labels[best], probability: p[best])
  }
}
