import Foundation

actor UKReferencePackage {
  static let provenance = "UK Reference · XLSR 2c733782da5604684829819a5eb744c193fe9398 · UK heads v1 · SwiftF0 64700fce · ONNX Runtime 1.24.2" + " · " + UKReferenceEvidence.policy + " · " + UKReferenceQuality.policy + " · " + UKVoiceActivity.policy + " · " + UKPhoneInventory.parsingPolicy + " · package " + manifestHash
  // Pinned only by the explicit freeze script after model verification.
  static let manifestHash = "f0f09be146b80e4c6ffaad5cac7f6ad1c561742e78529f2e9566feadf875006d"
  let directory: URL
  private let bundled: URL?
  /// `verify` hashes every file in `checksums.json`, `encoder.onnx` (1,26 GB) included, and
  /// `validate()` runs before every assessment — twice per PhoneticXeus job. This package owns the
  /// installed copy, so it keeps each hash until `stat` says the file changed.
  private let checksums = ModelChecksumCache()
  init(paths: BackendPaths, bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("UKReference")) {
    directory = paths.packages.appendingPathComponent("UKReference/v1")
    self.bundled = bundled
  }
  func installed() -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("verified.txt").path) }
  func validate() throws -> URL {
    guard installed() else { throw BuddyError.modelMissing }
    try Self.verify(directory, cache: checksums)
    return directory
  }
  /// Executable code stays in the signed app bundle; installed model data stays
  /// in the container. macOS can reject execution from writable package storage.
  func helperExecutable() throws -> URL {
    guard let bundled else { throw BuddyError.modelMissing }
    let manifest = bundled.appendingPathComponent("checksums.json")
    guard try BuddyModelPackage.checksum(manifest) == Self.manifestHash else { throw BuddyError.checksum }
    let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
    let executable = bundled.appendingPathComponent("espeak-ng")
    guard let expected = hashes["espeak-ng"], try BuddyModelPackage.checksum(executable) == expected else { throw BuddyError.checksum }
    return executable
  }
  func install() throws {
    guard let bundled else { throw BuddyError.modelMissing }
    try Self.verify(bundled)
    let fm = FileManager.default, parent = directory.deletingLastPathComponent()
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
  /// Without a `cache` every byte is read again — what a fresh install wants. `validate()` passes
  /// this package's cache so a repeat check of unchanged files costs a `stat` each.
  static func verify(_ directory: URL, cache: ModelChecksumCache? = nil) throws {
    func checksum(_ url: URL) throws -> String { try cache?.hash(url) ?? BuddyModelPackage.checksum(url) }
    let manifestURL = directory.appendingPathComponent("checksums.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw BuddyError.modelMissing }
    guard try checksum(manifestURL) == manifestHash else { throw BuddyError.checksum }
    let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
    for name in ["encoder.onnx", "vad.onnx", "vocab.json", "uk-vowels.json", "uk-focus.json", "uk-stress.json", "uk-boundary.json", "espeak-ng", "pitch.onnx", "espeak-ng-data/en_dict"] {
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
