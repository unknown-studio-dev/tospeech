import AVFAudio
import Foundation
import OnnxRuntimeBindings

protocol PhoneScoring: Sendable {
  func assess(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL,
    words: [PronunciationWordTarget], accent: ReferenceAccent) async throws -> PronunciationEvidence
  /// Drops everything this engine keeps warm between jobs. Called when the user moves to another
  /// engine: a warm helper process and an encoder session cost gigabytes that the active engine
  /// needs. The next `assess` rebuilds whatever it needs, so this is always safe.
  func release() async
}
extension PhoneScoring {
  /// Most engines keep nothing between jobs.
  func release() async {}
}

/// The US ordinal model owns both the CTC alignment and scores. Buddy is never
/// called by this adapter; an unsupported accent or alignment fails explicitly.
actor PhoneScorerAdapter: PhoneScoring {
  let package: PhoneScorerPackage
  init(package: PhoneScorerPackage) { self.package = package }

  func assess(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL,
    words: [PronunciationWordTarget], accent: ReferenceAccent) async throws -> PronunciationEvidence {
    guard accent == .us else { throw PhoneScorerError.unsupportedAccent }
    let directory = try await package.validate()
    let vocabulary = PhoneScorerMath.vocabulary
    // Scoring requires a complete authoritative expected sequence, not skipped
    // unknown words or a guessed pronunciation generated from ASR output.
    let targets = try words.map { word -> (PronunciationWordTarget, String, [PhoneScorerMath.Unit]) in
      guard let variant = word.variants.first,
        let parsed = PhoneInventory.parse(variant), !parsed.isEmpty else { throw PhoneScorerError.unsupportedPhones }
      let mapped = PhoneScorerMath.units(parsed)
      guard mapped.allSatisfy({ vocabulary.contains($0.symbol) }) else { throw PhoneScorerError.unsupportedPhones }
      return (word, variant, mapped)
    }
    let symbols = targets.flatMap { $0.2.map(\.symbol) }
    guard !symbols.isEmpty, symbols.count <= 512 else { throw PhoneScorerError.unsupportedPhones }
    let ids = symbols.map { vocabulary.firstIndex(of: $0)! }
    let source = try Self.infer(url: sourceURL, span: sourceSpan, ids: ids, directory: directory)
    try Task.checkCancellation()
    let take = try Self.infer(url: takeURL, span: nil, ids: ids, directory: directory)
    var index = 0
    let scored = targets.map { target, ipa, phones -> WordPronunciationEvidence in
      var differences: [PhoneDifference] = []
      for (offset, unit) in phones.enumerated() {
        let i = index + offset
        let supported = source.scores[i] >= PhoneScorerMath.correctThreshold
        for symbol in unit.displayPhones {
          differences.append(PhoneDifference(id: differences.count, kind: supported ? .scored : .referenceUncertain,
            expected: symbol, observed: nil, start: Double(take.spans[i].start)*0.02,
            end: min(take.duration, Double(take.spans[i].end)*0.02),
            quality: supported ? PhoneScorerMath.quality(take.scores[i]) : .unassessed,
            score: take.scores[i], sourceScore: source.scores[i], scoredUnit: unit.displayPhones.joined()))
        }
      }
      index += phones.count
      return WordPronunciationEvidence(target: target, referenceIPA: ipa, phones: differences, supported: true)
    }
    return PronunciationEvidence(words: scored, duration: take.duration, recognizedPhones: [],
      qualityPolicy: PhoneScorerMath.policy)
  }

  private struct Output {
    let duration: Double
    let spans: [CTCAlignment.Span]
    let scores: [Double]
  }

  private static func infer(url: URL, span: AudioSpan?, ids: [Int], directory: URL) throws -> Output {
    let file = try AVAudioFile(forReading: url)
    let fileDuration = Double(file.length)/file.processingFormat.sampleRate
    let start = span?.start ?? 0, end = span?.end ?? fileDuration
    guard start.isFinite, end.isFinite, start >= 0, end <= fileDuration, end > start else { throw BuddyError.invalidAudio }
    guard end-start <= 30 else { throw BuddyError.tooLong }
    var samples = try CoreMLWordAligner.samples(file: file, start: start, end: end)
    guard samples.count >= 8000, samples.allSatisfy(\.isFinite) else { throw BuddyError.invalidAudio }
    let power = samples.reduce(0.0) { $0 + Double($1)*Double($1) }/Double(samples.count)
    guard power > 1e-8 else { throw BuddyError.noSpeech }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--phone-scorer-probe") {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-probe-input.f32")
      try samples.withUnsafeBytes { Data($0) }.write(to: url)
      print("PHONE_INPUT: \(samples.count) samples, \(url.path)")
    }
    #endif
    let length = samples.count
    samples += Array(repeating: 0, count: (320-length%320)%320)
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(2)
    let acoustic = try ORTSession(env: env, modelPath: directory.appendingPathComponent("acoustic.onnx").path, sessionOptions: options)
    let output = try acoustic.run(withInputs: [
      "samples": tensor(samples, shape: [1, samples.count]),
      "valid_samples": integerTensor([Int64(length)], shape: [1])
    ], outputNames: ["hidden", "logits"], runOptions: nil)
    try Task.checkCancellation()
    let frames = (length+319)/320
    guard let hidden = output["hidden"], let logits = output["logits"] else { throw BuddyError.invalidOutput }
    let hiddenValues = try floats(hidden, width: 384, minimumFrames: frames)
    let logitsValues = try floats(logits, width: 45, minimumFrames: frames)
    let rows = try PhoneScorerMath.logProbabilities(Array(logitsValues.prefix(frames*45)), width: 45)
    guard let spans = try CTCAlignment.align(logProbabilities: rows, labels: ids, blank: 44) else {
      throw PhoneScorerError.alignment
    }
    let features = try PhoneScorerMath.pool(hidden: Array(hiddenValues.prefix(frames*384)),
      logProbabilities: rows, spans: spans, ids: ids)
    let scorer = try ORTSession(env: env, modelPath: directory.appendingPathComponent("scorer.onnx").path, sessionOptions: options)
    let result = try scorer.run(withInputs: [
      "features": tensor(features, shape: [1, ids.count, 772]),
      "phone_ids": integerTensor(ids.map(Int64.init), shape: [1, ids.count])
    ], outputNames: ["scores"], runOptions: nil)
    guard let value = result["scores"], try value.tensorTypeAndShapeInfo().shape.map(\.intValue) == [1, ids.count] else {
      throw BuddyError.invalidOutput
    }
    let data = try value.tensorData() as Data
    guard data.count == ids.count*4 else { throw BuddyError.invalidOutput }
    let scores = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)).map(Double.init) }
    guard scores.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { throw BuddyError.invalidOutput }
    return Output(duration: end-start, spans: spans, scores: scores)
  }

  private static func tensor(_ floats: [Float], shape: [Int]) throws -> ORTValue {
    let bytes = floats.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    return try ORTValue(tensorData: bytes, elementType: .float, shape: shape.map(NSNumber.init(value:)))
  }
  private static func integerTensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
    let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    return try ORTValue(tensorData: bytes, elementType: .int64, shape: shape.map(NSNumber.init(value:)))
  }
  private static func floats(_ value: ORTValue, width: Int, minimumFrames: Int) throws -> [Float] {
    let shape = try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
    guard shape.count == 3, shape[0] == 1, shape[1] >= minimumFrames, shape[1] <= 1500, shape[2] == width else {
      throw BuddyError.invalidOutput
    }
    let data = try value.tensorData() as Data
    guard data.count == shape[1]*width*4 else { throw BuddyError.invalidOutput }
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard values.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
    return values
  }
}

enum PhoneScorerMath {
  static let vocabulary = ["aar","aor","aɪ","aʊ","b","d","dʒ","eyr","eɪ","f","h","i","iyr","j","k","l","m","n","oʊ","p","s","t","tʃ","u","v","w","z","æ","ð","ŋ","ɑ","ɔ","ɔɪ","ɛ","ɝ","ɡ","ɪ","ɹ","ɾ","ʃ","ʊ","ʌ","ʒ","θ"]
  static let policy = "phone-e16-us-standard-25-75-source-gate-v1"
  static let correctThreshold = 75.0
  struct Unit: Equatable {
    let symbol: String
    let displayPhones: [String]
  }
  static func units(_ phones: [String]) -> [Unit] {
    var result: [Unit] = [], index = 0
    let folds = ["ɑ": "aar", "ɔ": "aor", "ɛ": "eyr", "ɪ": "iyr"]
    while index < phones.count {
      let symbol = modelSymbol(phones[index])
      if index+1 < phones.count, modelSymbol(phones[index+1]) == "ɹ", let folded = folds[symbol] {
        result.append(Unit(symbol: folded, displayPhones: Array(phones[index...index+1])))
        index += 2
      } else {
        result.append(Unit(symbol: symbol, displayPhones: [phones[index]])); index += 1
      }
    }
    return result
  }
  static func modelSymbol(_ symbol: String) -> String {
    // Upstream g2p maps unstressed schwa to AH and rhotic schwa to ER.
    symbol == "ə" ? "ʌ" : PhoneInventory.canonical(symbol)
  }
  static func quality(_ score: Double) -> PronunciationQuality {
    guard score.isFinite, (0...100).contains(score) else { return .unassessed }
    return score >= correctThreshold ? .correct : score >= 25 ? .nearCorrect : .incorrect
  }
  static func logProbabilities(_ logits: [Float], width: Int) throws -> [[Float]] {
    guard width > 1, !logits.isEmpty, logits.count%width == 0, logits.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
    return stride(from: 0, to: logits.count, by: width).map { index in
      let row = Array(logits[index..<(index+width)])
      let maximum = row.max()!
      let normalizer = log(row.reduce(Float(0)) { $0 + exp($1-maximum) })
      return row.map { $0-maximum-normalizer }
    }
  }
  static func pool(hidden: [Float], logProbabilities: [[Float]], spans: [CTCAlignment.Span], ids: [Int]) throws -> [Float] {
    let frames = logProbabilities.count
    guard frames > 0, hidden.count == frames*384, hidden.allSatisfy(\.isFinite), spans.count == ids.count,
      logProbabilities.allSatisfy({ $0.count == 45 && $0.allSatisfy(\.isFinite) }) else { throw BuddyError.invalidOutput }
    var pooled: [Float] = []
    for (span, id) in zip(spans, ids) {
      guard span.start >= 0, span.end <= frames, span.end > span.start, (0..<44).contains(id) else { throw PhoneScorerError.alignment }
      let count = Float(span.end-span.start)
      var means = Array(repeating: Float(0), count: 384)
      for frame in span.start..<span.end { for d in 0..<384 { means[d] += hidden[frame*384+d]/count } }
      var variance = Array(repeating: Float(0), count: 384)
      var expected: Float = 0, competitor: Float = 0, entropy: Float = 0
      for frame in span.start..<span.end {
        for d in 0..<384 { variance[d] += pow(hidden[frame*384+d]-means[d], 2)/count }
        let probabilities = logProbabilities[frame].map { exp($0) }
        expected += probabilities[id]/count
        competitor += probabilities.enumerated().filter { $0.offset != id }.map(\.element).max()!/count
        entropy -= zip(probabilities, logProbabilities[frame]).reduce(Float(0)) { $0 + $1.0*$1.1 }/count
      }
      pooled += means + variance.map { sqrt($0) } + [expected, expected-competitor, entropy/log(45), count/Float(frames)]
    }
    guard pooled.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
    return pooled
  }
}

enum PhoneScorerError: Error, LocalizedError {
  case unsupportedAccent, unsupportedPhones, alignment, packageMissing
  var errorDescription: String? {
    switch self {
    case .unsupportedAccent: "assessment.phone_scorer.accent"
    case .unsupportedPhones: "assessment.phone_scorer.phones"
    case .alignment: "assessment.phone_scorer.alignment"
    case .packageMissing: "assessment.phone_scorer.package_missing"
    }
  }
}
