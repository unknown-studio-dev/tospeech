import AVFAudio
import Foundation
import OnnxRuntimeBindings

/// Pinned Silero 16 kHz graph. Recurrent state and 64-sample context reset per
/// clip; source and learner can never share VAD state.
enum UKVoiceActivity {
  static let policy = "silero-867c2aa6-16k-threshold0.5-min96ms-v1"
  static func analyze(sourceURL: URL, span: AudioSpan, takeURL: URL, directory: URL) throws -> UKVADEvidence {
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(1)
    let session = try ORTSession(env: env, modelPath: directory.appendingPathComponent("vad.onnx").path, sessionOptions: options)
    func read(_ url: URL, span: AudioSpan?) throws -> [AudioSpan] {
      let samples = try UKAudioInput.samples(url, span: span)
      return try segments(probabilities(samples: samples, session: session), duration: Double(samples.count)/16000)
    }
    return try .init(policy: policy, source: read(sourceURL, span: span), take: read(takeURL, span: nil))
  }
  static func probabilities(samples: [Float], session: ORTSession) throws -> [Double] {
    guard samples.count >= 640, samples.count <= 480_000, samples.allSatisfy(\.isFinite) else { throw BuddyError.invalidAudio }
    func tensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
      let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
      return try ORTValue(tensorData: bytes, elementType: .float, shape: shape)
    }
    var state = try tensor(Array(repeating: 0, count: 256), shape: [2,1,128])
    var rate: Int64 = 16000
    let rateData = withUnsafeBytes(of: &rate) { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let sr = try ORTValue(tensorData: rateData, elementType: .int64, shape: [])
    var context = Array(repeating: Float(0), count: 64), result: [Double] = []
    for start in stride(from: 0, to: samples.count, by: 512) {
      try Task.checkCancellation()
      var chunk = Array(samples[start..<min(start+512, samples.count)])
      chunk += Array(repeating: 0, count: 512-chunk.count)
      let input = try tensor(context+chunk, shape: [1,576])
      let outputs = try session.run(withInputs: ["input": input, "sr": sr, "state": state],
        outputNames: ["output", "stateN"], runOptions: nil)
      guard let output = outputs["output"], let next = outputs["stateN"],
        try output.tensorTypeAndShapeInfo().shape.map(\.intValue) == [1,1],
        try next.tensorTypeAndShapeInfo().shape.map(\.intValue) == [2,1,128] else { throw BuddyError.invalidOutput }
      let data = try output.tensorData() as Data
      guard data.count == 4 else { throw BuddyError.invalidOutput }
      let probability = data.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
      guard probability.isFinite else { throw BuddyError.invalidOutput }
      result.append(probability); state = next; context = Array(chunk.suffix(64))
    }
    return result
  }
  static func segments(_ probabilities: [Double], duration: Double) -> [AudioSpan] {
    var spans: [AudioSpan] = [], start: Int?, lastSpeech = 0
    func finish() {
      if let first = start, lastSpeech-first+1 >= 3 {
        spans.append(.init(start: Double(first)*0.032, end: min(duration, Double(lastSpeech+1)*0.032)))
      }
      start = nil
    }
    for (i, p) in probabilities.enumerated() {
      if p >= (start == nil ? 0.5 : 0.35) {
        if start == nil { start = i }; lastSpeech = i
      } else if start != nil, i-lastSpeech >= 4 { finish() }
    }
    finish()
    return spans
  }
}
