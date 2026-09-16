import Foundation

/// Native XEUS scorer orchestrator — the drop-in replacement for the Python helper launch in
/// `PhoneticXeusAdapter.assess`. It mirrors `serve.py`/`runtime.py`'s `run`: run the ONNX graph on
/// the source and take PCM (`XeusOnnxSession.logits` → logits + hidden), then hand both to
/// `XeusRuntime.assembleFromLogits` (Tasks 4-9) with the pinned calibrated thresholds and the loaded
/// contrast head, producing the `PhoneticXeusEvidence` the adapter converts.
///
/// RESILIENCE: every failure is THROWN (`XeusOnnxError`/`XeusRuntimeError`/ORT errors), never
/// trapped, so a malformed assessment fails the job gracefully — mirroring `serve.py`'s per-request
/// resilience — instead of crashing the app.
///
/// The ONNX session (which memory-maps `xeus.onnx.data`) is built lazily on the first assessment and
/// cached for the actor's lifetime. Tests that only need decision parity call `assemble(...)`
/// directly with saved logits, bypassing ORT and the graph entirely.
actor XeusOnnxScorer {
  /// The pinned calibration artifact `thresholds.json` (`native-zero-false-sai-v1`): competitor is
  /// 1.8, NOT the code default `ln 6`. These are the exact thresholds the golden decisions — and
  /// the shipped scorer — are calibrated with.
  static let thresholds = XeusRuntime.Thresholds(
    support: 0.30, margin: Foundation.log(4), entropy: 0.55, competitor: 1.8, strength: 0.65)
  static let calibration = "native-zero-false-sai-v1"

  static let graphName = "xeus.onnx"
  static let vocabName = "ipa_vocab.json"

  private let modelURL: URL
  private let vocab: [String: Int]
  private let head: XeusContrastHead?
  private var session: XeusOnnxSession?

  /// Production initializer: resolve the graph, vocab and contrast head from an installed package
  /// directory (`PhoneticXeusPackage.validate()`'s return). Throws on a broken vocabulary contract.
  init(directory: URL) throws {
    self.modelURL = directory.appendingPathComponent(Self.graphName)
    self.vocab = try Self.loadVocab(directory.appendingPathComponent(Self.vocabName))
    self.head = XeusContrastHead.load(directory.appendingPathComponent(XeusContrastHead.HEAD_FILE))
  }

  /// Direct initializer (tests / injected components): supply the graph URL, vocab, and head.
  init(modelURL: URL, vocab: [String: Int], head: XeusContrastHead?) {
    self.modelURL = modelURL
    self.vocab = vocab
    self.head = head
  }

  /// Port of `load`'s vocabulary contract check (`runtime.py:39`): exactly 428 entries, `<blank>`==0.
  static func loadVocab(_ url: URL) throws -> [String: Int] {
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
    guard vocab.count == 428, vocab["<blank>"] == 0 else { throw XeusOnnxError.vocabularyContract }
    return vocab
  }

  /// Full native path: PCM → logits+hidden (ORT) → evidence. `sourceDuration`/`takeDuration` are the
  /// clip lengths in seconds (`len(samples)/16000` in `runtime.py:151`).
  func evidence(source: [Float], take: [Float], request: XeusRequest,
    sourceDuration: Double, takeDuration: Double) throws -> PhoneticXeusEvidence {
    let session = try onnxSession()
    let (sourceLogits, sourceHidden) = try session.logits(source)
    try Task.checkCancellation()
    let (takeLogits, takeHidden) = try session.logits(take)
    try Task.checkCancellation()
    return try assemble(sourceLogits: sourceLogits, takeLogits: takeLogits,
      hiddenSource: sourceHidden, hiddenTake: takeHidden, request: request,
      sourceDuration: sourceDuration, takeDuration: takeDuration)
  }

  /// Pure decision path (ORT-free): assemble evidence from already-computed logits. This is the
  /// test-injectable entry for decision parity, and the shared core `evidence(...)` calls after ORT.
  func assemble(sourceLogits: [[Double]], takeLogits: [[Double]],
    hiddenSource: [[Float]]?, hiddenTake: [[Float]]?, request: XeusRequest,
    sourceDuration: Double, takeDuration: Double) throws -> PhoneticXeusEvidence {
    try XeusRuntime.assembleFromLogits(
      source: sourceLogits, take: takeLogits, hiddenSource: hiddenSource, hiddenTake: hiddenTake,
      vocab: vocab, request: request, sourceDuration: sourceDuration, takeDuration: takeDuration,
      thresholds: Self.thresholds, head: head)
  }

  private func onnxSession() throws -> XeusOnnxSession {
    if let session { return session }
    guard FileManager.default.fileExists(atPath: modelURL.path) else { throw XeusOnnxError.graphMissing }
    let created = try XeusOnnxSession(modelURL: modelURL)
    session = created
    return created
  }
}
