import AVFAudio
import Foundation
import OnnxRuntimeBindings

/// SwiftF0's original ONNX graph owns the STFT and pitch network. This is an
/// accent-independent pitch measurement, not a learned prosody-quality score.
enum UKPitchAdapter {
  static let policy = "swift-f0-16khz-hop256-confidence0.9-v1"
  static func analyze(sourceURL: URL, span: AudioSpan, takeURL: URL, directory: URL) throws -> UKPitchEvidence {
    let environment = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(1)
    let session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent("pitch.onnx").path, sessionOptions: options)
    return try .init(policy: policy, source: infer(sourceURL, span: span, session: session),
      take: infer(takeURL, span: nil, session: session))
  }
  private static func infer(_ url: URL, span: AudioSpan?, session: ORTSession) throws -> [UKPitchFrame] {
    let samples = try UKAudioInput.samples(url, span: span)
    try Task.checkCancellation()
    let bytes = samples.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let input = try ORTValue(tensorData: bytes, elementType: .float, shape: [1, NSNumber(value: samples.count)])
    let output = try session.run(withInputs: ["input_audio": input], outputNames: ["pitch_hz", "confidence"], runOptions: nil)
    func values(_ name: String) throws -> [Float] {
      guard let tensor = output[name] else { throw BuddyError.invalidOutput }
      let shape = try tensor.tensorTypeAndShapeInfo().shape
      guard shape.count == 2, shape[0].intValue == 1, shape[1].intValue == samples.count/256 else { throw BuddyError.invalidOutput }
      let data = try tensor.tensorData() as Data
      guard data.count == shape[1].intValue*4 else { throw BuddyError.invalidOutput }
      let result = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      guard result.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
      return result
    }
    let hz = try values("pitch_hz"), confidence = try values("confidence")
    try Task.checkCancellation()
    return hz.indices.map { .init(time: (Double($0*256)+127.5)/16000,
      hz: Double(hz[$0]), confidence: Double(confidence[$0])) }
  }
}
