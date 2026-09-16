import Foundation
import OnnxRuntimeBindings

/// ONNX Runtime wrapper around the exported single-file XEUS graph (`xeus.onnx` + `xeus.onnx.data`).
/// A native port of `runtime.py`'s `infer_with_hidden` (lines 62-80): mono-16k float32 PCM →
/// `(log_probs [T,428], hidden [T,dim])`, where `log_probs` is already `log_softmax`'d by the graph
/// (`export_onnx.py` wraps `ctc_lo(h).log_softmax(-1)`), and `hidden` is the contrast-head encoder
/// layer (layer 13, dim 1024) captured as a second graph output.
///
/// Inputs mirror the export contract (`export_onnx.py:195-201`): `values:[1,N] float32`,
/// `lengths:[1] int64`. Intra-op threads are pinned to 4 to match the Python `torch.set_num_threads(4)`.
struct XeusOnnxSession {
  static let vocabSize = 428

  private let env: ORTEnv
  private let session: ORTSession

  init(modelURL: URL, intraOpThreads: Int = 4) throws {
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(Int32(intraOpThreads))
    self.env = env
    self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
  }

  /// Port of `infer_with_hidden`: run the graph on `samples` and return `(logits, hidden)`.
  /// `logits` is `[T][428]` upcast to `Double` (the decision pipeline runs in `Double`); `hidden`
  /// is `[T][dim]` kept as `Float` (the encoder dtype), or `nil` when the graph omits it or its
  /// shape disagrees with the logits' frame count — matching Python's "drop mismatched hidden".
  func logits(_ samples: [Float]) throws -> (logits: [[Double]], hidden: [[Float]]?) {
    guard samples.count >= 800, samples.count <= 480_000, samples.allSatisfy(\.isFinite) else {
      throw XeusOnnxError.invalidInput
    }
    let values = try Self.floatTensor(samples, shape: [1, samples.count])
    let lengths = try Self.int64Tensor([Int64(samples.count)], shape: [1])
    let outputs = try session.run(withInputs: ["values": values, "lengths": lengths],
      outputNames: ["log_probs", "hidden"], runOptions: nil)
    try Task.checkCancellation()

    guard let lpValue = outputs["log_probs"] else { throw XeusOnnxError.invalidOutput }
    let lpShape = try lpValue.tensorTypeAndShapeInfo().shape.map(\.intValue)
    guard lpShape.count == 3, lpShape[0] == 1, lpShape[2] == Self.vocabSize, lpShape[1] >= 1, lpShape[1] <= 1600 else {
      throw XeusOnnxError.invalidOutput
    }
    let frames = lpShape[1]
    let lpData = try lpValue.tensorData() as Data
    guard lpData.count == frames * Self.vocabSize * 4 else { throw XeusOnnxError.invalidOutput }
    let lpFloats = lpData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard lpFloats.allSatisfy(\.isFinite) else { throw XeusOnnxError.invalidOutput }
    var lp = [[Double]]()
    lp.reserveCapacity(frames)
    for f in 0..<frames {
      var row = [Double](repeating: 0, count: Self.vocabSize)
      for c in 0..<Self.vocabSize { row[c] = Double(lpFloats[f * Self.vocabSize + c]) }
      lp.append(row)
    }

    var hidden: [[Float]]? = nil
    if let hValue = outputs["hidden"],
      let hShape = try? hValue.tensorTypeAndShapeInfo().shape.map(\.intValue),
      hShape.count == 3, hShape[0] == 1, hShape[1] == frames, hShape[2] > 0 {
      let dim = hShape[2]
      if let hData = try? hValue.tensorData() as Data, hData.count == frames * dim * 4 {
        let hFloats = hData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if hFloats.allSatisfy(\.isFinite) {
          var rows = [[Float]]()
          rows.reserveCapacity(frames)
          for f in 0..<frames { rows.append(Array(hFloats[(f * dim)..<((f + 1) * dim)])) }
          hidden = rows
        }
      }
    }
    return (lp, hidden)
  }

  private static func floatTensor(_ floats: [Float], shape: [Int]) throws -> ORTValue {
    let bytes = floats.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    return try ORTValue(tensorData: bytes, elementType: .float, shape: shape.map(NSNumber.init(value:)))
  }
  private static func int64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
    let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    return try ORTValue(tensorData: bytes, elementType: .int64, shape: shape.map(NSNumber.init(value:)))
  }
}

/// Errors from the native ONNX scorer path. Thrown (never trapped) so a malformed assessment fails
/// the job gracefully — mirroring `serve.py`'s resilience — instead of crashing the app.
enum XeusOnnxError: Error, LocalizedError, Equatable {
  case invalidInput
  case invalidOutput
  case vocabularyContract
  case graphMissing

  var errorDescription: String? {
    switch self {
    case .invalidInput: return "assessment.xeus.invalid_input"
    case .invalidOutput: return "assessment.xeus.invalid_output"
    case .vocabularyContract: return "assessment.xeus.vocabulary_contract"
    case .graphMissing: return "assessment.xeus.graph_missing"
    }
  }
}
