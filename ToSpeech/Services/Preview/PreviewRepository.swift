import Foundation

struct PreviewRepository {
  var url: URL?
  static var local: Self {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return Self(url: root.appendingPathComponent("ToSpeech/NativePreview/snapshot-v1.json"))
  }
  static var memory: Self { Self(url: nil) }
  func load() throws -> PreviewSnapshot? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Self.droppingRetiredEngines(Data(contentsOf: url))
    let snapshot = try JSONDecoder().decode(PreviewSnapshot.self, from: data)
    guard snapshot.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
    return snapshot
  }

  /// Engines removed from the app (Whisper, GOPT) survive in older snapshots as
  /// packages, take assessments and the active-engine preference. Decoding an
  /// unknown `EngineID` would reject the whole file and lose the user's lessons,
  /// so those entries are dropped and everything else is kept.
  static func droppingRetiredEngines(_ data: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
    let known = Set(EngineID.allCases.map(\.rawValue))
    func isKnown(_ value: Any?) -> Bool { (value as? String).map(known.contains) ?? false }
    var changed = false
    if let packages = object["packages"] as? [[String: Any]] {
      let kept = packages.filter { isKnown($0["id"]) }
      changed = changed || kept.count != packages.count
      object["packages"] = kept
    }
    if let takes = object["takes"] as? [[String: Any]] {
      object["takes"] = takes.map { take -> [String: Any] in
        guard let assessments = take["assessments"] as? [[String: Any]] else { return take }
        let kept = assessments.filter { isKnown($0["engine"]) }
        changed = changed || kept.count != assessments.count
        var take = take
        take["assessments"] = kept
        return take
      }
    }
    if var preferences = object["preferences"] as? [String: Any] {
      for key in ["activeEngine", "productionAssessmentEngine"] where preferences[key] != nil && !isKnown(preferences[key]) {
        preferences[key] = nil
        changed = true
      }
      object["preferences"] = preferences
    }
    return changed ? try JSONSerialization.data(withJSONObject: object) : data
  }
  func save(_ snapshot: PreviewSnapshot) throws {
    guard let url else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
  }
}
