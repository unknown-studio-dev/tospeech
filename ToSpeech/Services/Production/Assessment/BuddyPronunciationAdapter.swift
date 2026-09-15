import AVFAudio
import Foundation
import OnnxRuntimeBindings

protocol PronunciationRecognizing: Sendable {
  func recognize(audioURL: URL, span: AudioSpan?) async throws -> (phones: [RecognizedPhone], duration: Double)
}

actor BuddyPronunciationAdapter: PronunciationRecognizing {
  let package: BuddyModelPackage
  init(package: BuddyModelPackage) { self.package = package }

  func recognize(audioURL: URL, span: AudioSpan?) async throws -> (phones: [RecognizedPhone], duration: Double) {
    let directory = try await package.validate()
    try Task.checkCancellation()
    return try Self.infer(audioURL: audioURL, directory: directory, span: span)
  }

  // Synchronous ORT objects and AV buffers stay within this actor's executor.
  private static func infer(audioURL: URL, directory: URL, span: AudioSpan?) throws -> (phones: [RecognizedPhone], duration: Double) {
    let file = try AVAudioFile(forReading: audioURL)
    let fileDuration = Double(file.length) / file.processingFormat.sampleRate
    let start = span?.start ?? 0, end = span?.end ?? fileDuration
    guard start.isFinite, end.isFinite, start >= 0, end <= fileDuration, end > start else { throw BuddyError.invalidAudio }
    let duration = end - start
    guard duration.isFinite, duration > 0.1 else { throw BuddyError.invalidAudio }
    guard duration <= 30 else { throw BuddyError.tooLong }
    let raw = try CoreMLWordAligner.samples(file: file, start: start, end: end)
    guard raw.count >= 400, raw.allSatisfy(\.isFinite) else { throw BuddyError.invalidAudio }
    let mean = raw.reduce(0.0) { $0 + Double($1) } / Double(raw.count)
    let variance = raw.reduce(0.0) { $0 + pow(Double($1)-mean, 2) } / Double(raw.count)
    guard variance > 1e-8 else { throw BuddyError.noSpeech }
    let samples = raw.map { Float((Double($0)-mean)/(sqrt(variance)+1e-7)) }
    let data = samples.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(2)
    let session = try ORTSession(env: env, modelPath: directory.appendingPathComponent("model.int8.onnx").path, sessionOptions: options)
    let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: samples.count)])
    let names = try session.outputNames()
    guard let name = names.first else { throw BuddyError.invalidOutput }
    let output = try session.run(withInputs: ["input_values": input], outputNames: Set([name]), runOptions: nil)
    try Task.checkCancellation()
    guard let tensor = output[name] else { throw BuddyError.invalidOutput }
    let info = try tensor.tensorTypeAndShapeInfo()
    guard info.shape.count == 3, info.shape[0].intValue == 1 else { throw BuddyError.invalidOutput }
    let frames = info.shape[1].intValue, width = info.shape[2].intValue
    guard (125...127).contains(width), frames > 0, frames <= 1600 else { throw BuddyError.invalidOutput }
    let bytes = try tensor.tensorData() as Data
    guard bytes.count == frames * width * MemoryLayout<Float>.size else { throw BuddyError.invalidOutput }
    let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
    let tokens = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })
    let phones = try decode(values, frames: frames, width: width, tokens: tokens, duration: duration)
    guard !phones.isEmpty, phones.contains(where: { $0.symbol != "?" }) else { throw BuddyError.noSpeech }
    return (phones, duration)
  }

  nonisolated static func decode(_ values: [Float], frames: Int, width: Int,
    tokens: [Int: String], duration: Double) throws -> [RecognizedPhone] {
    guard width >= 125, frames > 0, values.count == frames * width else { throw BuddyError.invalidOutput }
    var result: [RecognizedPhone] = []
    var previous = -1
    for t in 0..<frames {
      let row = Array(values[(t*width)..<((t+1)*width)])
      guard row.allSatisfy(\.isFinite), let maxID = row.indices.max(by: { row[$0] < row[$1] }) else { throw BuddyError.invalidOutput }
      let probability = 1 / Double(row.reduce(Float(0)) { $0 + exp($1-row[maxID]) })
      if maxID != 124 && maxID != 0 {
        let symbol = tokens[maxID].flatMap(PhoneInventory.fromARPAbet) ?? "?"
        if maxID == previous, let last = result.last {
          result[result.count-1] = RecognizedPhone(symbol: last.symbol, start: last.start,
            end: min(duration, Double(t+1)*0.02+0.025), posterior: max(last.posterior, probability))
        } else {
          result.append(RecognizedPhone(symbol: symbol, start: Double(t)*0.02,
            end: min(duration, Double(t+1)*0.02+0.025), posterior: probability))
        }
      }
      previous = maxID
    }
    guard result.count <= 512 else { throw BuddyError.tooLong }
    return result
  }
}
