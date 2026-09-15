import AVFAudio
import Foundation
import OnnxRuntimeBindings

/// Everything the UK pipeline can measure before the target variants are known: both encoder
/// passes, pitch and voice activity. The XEUS branch computes this while the helper works.
struct UKAcoustics: Sendable {
  let directory: URL
  let vocabulary: [String: Int]
  let span: AudioSpan
  let pitch: UKPitchEvidence
  let vad: UKVADEvidence
  let source: UKReferenceAdapter.Acoustic
  let take: UKReferenceAdapter.Acoustic
}

/// A single local UK pipeline. Raw acoustic distances remain measurements until
/// a scoring head has a declared calibration; they are never percentage grades.
actor UKReferenceAdapter: PhoneScoring {
  let package: UKReferencePackage
  private var idle: IdleRelease
  private var idleTask: Task<Void, Never>?
  init(package: UKReferencePackage, idleTimeout: Duration = AssessmentResourcePolicy.current().idleTimeout,
    clock: any Clock<Duration> = ContinuousClock()) {
    self.package = package
    idle = IdleRelease(timeout: idleTimeout, clock: clock)
  }
  struct Acoustic: Sendable {
    let hidden: UKReferenceMath.Matrix
    let rows: [[Float]]
    let duration: Double
  }
  private struct Target {
    let word: PronunciationWordTarget
    let ipa: String
    let units: [UKPhoneInventory.Unit]
    let labels: [[Int]]
    let sourceSpans: [CTCAlignment.Span]
  }
  private var cachedSource: (key: String, acoustic: Acoustic)?
  /// The encoder session holds ~1.5 GB. It stays warm between takes of the same session and is
  /// released once nothing has used it for `idleTimeout`.
  private var cachedEncoder: (directory: URL, environment: ORTEnv, session: ORTSession)?

  func assess(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL,
    words: [PronunciationWordTarget], accent: ReferenceAccent) async throws -> PronunciationEvidence {
    guard accent == .uk else { throw UKReferenceError.accent }
    guard !words.isEmpty, words.count <= 128 else { throw BuddyError.tooLong }
    return try await score(acoustics(sourceURL: sourceURL, sourceSpan: sourceSpan, takeURL: takeURL), words: words)
  }

  func acoustics(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL) async throws -> UKAcoustics {
    let directory = try await package.validate()
    let vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
    var mark = ContinuousClock.now
    let pitch = try UKPitchAdapter.analyze(sourceURL: sourceURL, span: sourceSpan, takeURL: takeURL, directory: directory)
    AssessmentStage.log("uk.acoustics.pitch", since: mark)
    // Forced alignment alone can assign expected phones to non-speech audio.
    mark = .now
    let vad = try UKVoiceActivity.analyze(sourceURL: sourceURL, span: sourceSpan, takeURL: takeURL, directory: directory)
    AssessmentStage.log("uk.acoustics.vad", since: mark)
    guard !vad.take.isEmpty else { throw BuddyError.noSpeech }
    guard !vad.source.isEmpty else { throw UKReferenceError.alignment }
    let key = try BuddyModelPackage.checksum(sourceURL)+"/\(sourceSpan.start)/\(sourceSpan.end)"
    // The ORT session build is part of a cold source pass; `session=` reports it separately.
    mark = .now
    let (source, take) = try withEncoder(directory: directory) { session in
      let sessionSeconds = AssessmentStage.seconds(since: mark)
      let source: Acoustic
      let cached = cachedSource?.key == key
      if cached { source = cachedSource!.acoustic }
      else {
        source = try Self.infer(sourceURL, span: sourceSpan, session: session)
        cachedSource = (key, source)
      }
      AssessmentStage.log("uk.acoustics.encoder.source", since: mark,
        "cached=\(cached) session=\(String(format: "%.4f", sessionSeconds))")
      try Task.checkCancellation()
      let takeMark = ContinuousClock.now
      let take = try Self.infer(takeURL, span: nil, session: session)
      AssessmentStage.log("uk.acoustics.encoder.take", since: takeMark)
      return (source, take)
    }
    return .init(directory: directory, vocabulary: vocabulary, span: sourceSpan,
      pitch: pitch, vad: vad, source: source, take: take)
  }

  func score(_ acoustics: UKAcoustics, words: [PronunciationWordTarget]) async throws -> PronunciationEvidence {
    guard !words.isEmpty, words.count <= 128 else { throw BuddyError.tooLong }
    let directory = acoustics.directory, vocabulary = acoustics.vocabulary, sourceSpan = acoustics.span
    let source = acoustics.source, take = acoustics.take
    try Self.validateTargets(words, vocabulary: vocabulary)
    var mark = ContinuousClock.now
    var targets: [Target] = []
    // Anchor source words with the lesson's saved alignment; choose UK variants
    // using source evidence, then lock exactly that path for the learner.
    let anchoredWords = try Self.anchor(words, source: source, sourceSpan: sourceSpan, vocabulary: vocabulary)
    for word in anchoredWords {
      guard let start = word.sourceStart, let end = word.sourceEnd, end > start else { throw UKReferenceError.wordTiming }
      let lower = max(0, Int(floor((start-sourceSpan.start)/0.02)))
      let upper = min(source.rows.count, Int(ceil((end-sourceSpan.start)/0.02)))
      guard upper > lower else { throw UKReferenceError.wordTiming }
      let rows = Array(source.rows[lower..<upper])
      var best: (Target, Double)?
      for ipa in Array(Set(word.variants)).sorted() {
        guard let units = UKPhoneInventory.parse(ipa) else { continue }
        let encoded = units.map { UKPhoneInventory.ctcTokens($0.symbol, vocabulary: vocabulary) }
        guard encoded.allSatisfy({ $0 != nil }) else { continue }
        let labels = encoded.compactMap { $0 }
        guard let spans = try CTCAlignment.align(logProbabilities: rows, labels: labels.flatMap { $0 }) else { continue }
        let support = UKReferenceMath.support(rows, labels: labels.flatMap { $0 }, spans: spans)
        let target = Target(word: word, ipa: ipa, units: units, labels: labels,
          sourceSpans: spans.map { .init(start: $0.start+lower, end: $0.end+lower) })
        if best == nil || support > best!.1 { best = (target, support) }
      }
      guard let best else { throw UKReferenceError.wordAlignment(word.text) }
      targets.append(best.0)
    }
    let labels = targets.flatMap { $0.labels.flatMap { $0 } }
    guard labels.count <= 512, let takeSpans = try CTCAlignment.align(logProbabilities: take.rows, labels: labels) else { throw UKReferenceError.alignment }
    AssessmentStage.log("uk.score.anchor+align", since: mark)
    mark = .now
    let head = try UKVowelHead.load(directory: directory)
    let focusHead = try UKVowelHead.load(directory: directory, name: "uk-focus.json")
    let stressHead = try UKVowelHead.load(directory: directory, name: "uk-stress.json")
    let boundaryHead = try UKVowelHead.load(directory: directory, name: "uk-boundary.json")
    var boundaries: [UKBoundaryEvidence] = []
    var focus: [UKFocusEvidence] = [], stress: [UKStressEvidence] = []
    var measurements: [String: [UKPhoneMeasurement]] = [:], results: [WordPronunciationEvidence] = []
    var cursor = 0
    for target in targets {
      try Task.checkCancellation()
      var differences: [PhoneDifference] = [], measured: [UKPhoneMeasurement] = []
      var focusCandidates: [(Double, Double, Double, Double)] = []
      var unitCursor = 0
      let sourceAnchors = target.labels.map { ids -> CTCAlignment.Span in
        defer { unitCursor += ids.count }
        return .init(start: target.sourceSpans[unitCursor].start, end: target.sourceSpans[unitCursor+ids.count-1].end)
      }
      unitCursor = cursor
      let takeAnchors = target.labels.map { ids -> CTCAlignment.Span in
        defer { unitCursor += ids.count }
        return .init(start: takeSpans[unitCursor].start, end: takeSpans[unitCursor+ids.count-1].end)
      }
      let sourceRegions = UKReferenceMath.regions(sourceAnchors,
        lower: sourceAnchors.first!.start, upper: sourceAnchors.last!.end)
      let takeRegions = UKReferenceMath.regions(takeAnchors, lower: takeAnchors.first!.start, upper: takeAnchors.last!.end)
      guard sourceRegions.count == target.units.count, takeRegions.count == target.units.count else { throw UKReferenceError.alignment }
      let nuclei = target.units.indices.filter { target.units[$0].isNucleus }
      if nuclei.count > 1 {
        var sourceProbabilities: [Double] = [], takeProbabilities: [Double] = []
        for (number, vowel) in nuclei.enumerated() {
          // Approximate syllable splits between vowel anchors; keep these separate
          // from the manually timed training evaluation and never call them gold.
          let first = number == 0 ? 0 : (nuclei[number-1]+vowel+1)/2
          let last = number+1 == nuclei.count ? target.units.count-1 : (vowel+nuclei[number+1]+1)/2-1
          let aSpan = CTCAlignment.Span(start: sourceRegions[first].start, end: sourceRegions[last].end)
          let bSpan = CTCAlignment.Span(start: takeRegions[first].start, end: takeRegions[last].end)
          if let a = UKReferenceMath.mean(source.hidden, start: aSpan.start, end: aSpan.end),
            let b = UKReferenceMath.mean(take.hidden, start: bSpan.start, end: bSpan.end),
            let ap = stressHead.probabilities(a+[log(Double(aSpan.end-aSpan.start)*0.02)])?.last,
            let bp = stressHead.probabilities(b+[log(Double(bSpan.end-bSpan.start)*0.02)])?.last {
            sourceProbabilities.append(ap); takeProbabilities.append(bp)
          }
        }
        if sourceProbabilities.count == nuclei.count {
          stress.append(.init(id: target.word.id, text: target.word.text,
            expectedSyllable: nuclei.firstIndex(where: { target.units[$0].stress == 1 }).map { $0+1 },
            sourceProbabilities: sourceProbabilities, takeProbabilities: takeProbabilities,
            source: .init(start: Double(sourceRegions.first!.start)*0.02, end: min(source.duration, Double(sourceRegions.last!.end)*0.02)),
            take: .init(start: Double(takeRegions.first!.start)*0.02, end: min(take.duration, Double(takeRegions.last!.end)*0.02)), model: stressHead.policy))
        }
      }
      var wordCursor = 0
      for (index, unit) in target.units.enumerated() {
        let ids = target.labels[index]
        let sourcePieces = Array(target.sourceSpans[wordCursor..<(wordCursor+ids.count)])
        let takePieces = Array(takeSpans[cursor..<(cursor+ids.count)])
        let sourceRegion = sourceRegions[index]
        let takeRegion = takeRegions[index]
        guard let a = UKReferenceMath.mean(source.hidden, start: sourceRegion.start, end: sourceRegion.end),
          let b = UKReferenceMath.mean(take.hidden, start: takeRegion.start, end: takeRegion.end),
          let distance = UKReferenceMath.cosineDistance(a,b) else { throw BuddyError.invalidOutput }
        let sourceSupport = UKReferenceMath.support(source.rows, labels: ids, spans: sourcePieces)
        let takeSupport = UKReferenceMath.support(take.rows, labels: ids, spans: takePieces)
        let sourceTime = AudioSpan(start: Double(sourceRegion.start)*0.02, end: min(source.duration, Double(sourceRegion.end)*0.02+0.025))
        let takeTime = AudioSpan(start: Double(takeRegion.start)*0.02, end: min(take.duration, Double(takeRegion.end)*0.02+0.025))
        let sourcePrediction = unit.isVowel ? head.predict(a) : nil
        let takePrediction = unit.isVowel ? head.predict(b) : nil
        let decision = UKReferenceQuality.decide(expected: unit.symbol, supported: head.labels,
          source: sourcePrediction, take: takePrediction, floor: head.confidenceFloor)
        if unit.isVowel,
          let sourceFocus = focusHead.probabilities(a+[log(max(0.02, sourceTime.duration))])?.last,
          let takeFocus = focusHead.probabilities(b+[log(max(0.02, takeTime.duration))])?.last,
          let sourceBoundary = boundaryHead.probabilities(a+[log(max(0.02, sourceTime.duration))])?.last,
          let takeBoundary = boundaryHead.probabilities(b+[log(max(0.02, takeTime.duration))])?.last {
          focusCandidates.append((sourceFocus, takeFocus, sourceBoundary, takeBoundary))
        }
        differences.append(.init(id: index, kind: decision.kind, expected: unit.symbol, observed: decision.observed,
          start: takeTime.start, end: takeTime.end, quality: decision.quality,
          unassessedReason: decision.quality != .unassessed ? nil :
            decision.kind == .referenceUncertain ? .referenceUncertain :
            decision.kind == .uncertain ? .takeUncertain : .outsideModel))
        measured.append(.init(source: sourceTime, take: takeTime, acousticDistance: distance,
          sourceTokenSupport: sourceSupport, takeTokenSupport: takeSupport,
          predictedVowel: takePrediction?.symbol, vowelProbability: takePrediction?.probability,
          sourceVowel: sourcePrediction?.symbol, sourceVowelProbability: sourcePrediction?.probability))
        wordCursor += ids.count; cursor += ids.count
      }
      if let first = measured.first, let last = measured.last,
        let nucleus = focusCandidates.max(by: { $0.0 < $1.0 }) {
        focus.append(.init(id: target.word.id, text: target.word.text,
          source: .init(start: first.source.start, end: last.source.end),
          take: .init(start: first.take.start, end: last.take.end),
          sourceProbability: nucleus.0, takeProbability: nucleus.1, model: focusHead.policy))
        boundaries.append(.init(id: target.word.id, text: target.word.text,
          source: .init(start: first.source.start, end: last.source.end),
          take: .init(start: first.take.start, end: last.take.end),
          sourceProbability: nucleus.2, takeProbability: nucleus.3, model: boundaryHead.policy))
      }
      measurements[target.word.id] = measured
      results.append(.init(target: target.word, referenceIPA: target.ipa, phones: differences, supported: true, inventory: UKPhoneInventory.version))
    }
    let evidence = PronunciationEvidence(words: results, duration: take.duration, recognizedPhones: [],
      qualityPolicy: UKReferenceQuality.policy,
      ukReference: .init(inventory: UKPhoneInventory.version, modelRevision: UKReferencePackage.provenance,
        calibration: head.policy, sourceDuration: source.duration, measurements: measurements, focus: focus, stress: stress, pitch: acoustics.pitch, vad: acoustics.vad, boundaries: boundaries,
        targetParsingPolicy: UKPhoneInventory.parsingPolicy))
    AssessmentStage.log("uk.score.heads", since: mark)
    return evidence
  }

  /// Drops the encoder session and the cached source acoustics immediately. Unlike the idle
  /// release — which keeps `cachedSource` so repeat takes of one sentence stay cheap — an engine
  /// change means nothing of this engine is wanted in memory any more.
  func release() async {
    idleTask?.cancel(); idleTask = nil
    cachedEncoder = nil
    cachedSource = nil
  }

  /// Everything that needs the ~1.5 GB encoder session runs in here, because every exit from this
  /// scope — a clean return, a throw, a cancellation — has to leave the session on the idle timer.
  /// A job that failed after the session was built used to strand it with no timer at all, and a
  /// failed XEUS job cancels this branch as a matter of course.
  private func withEncoder<T>(directory: URL, _ body: (ORTSession) throws -> T) throws -> T {
    let session = try encoder(directory: directory)
    defer { scheduleEncoderRelease() }
    return try body(session)
  }

  /// Keeps the encoder warm across takes of the same practice session.
  private func encoder(directory: URL) throws -> ORTSession {
    if let cachedEncoder, cachedEncoder.directory == directory { return cachedEncoder.session }
    let environment = try ORTEnv(loggingLevel: .warning)
    // Two intra-op threads: the XEUS helper runs beside this on the same performance cores.
    let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2)
    let session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent("encoder.onnx").path, sessionOptions: options)
    cachedEncoder = (directory, environment, session)
    return session
  }
  private func scheduleEncoderRelease() {
    let mark = idle.mark()
    idleTask?.cancel()
    idleTask = Task { [idle, weak self] in
      await idle.waitForIdle()
      await self?.releaseEncoder(mark)
    }
  }
  private func releaseEncoder(_ mark: Int) {
    guard idle.isCurrent(mark) else { return }
    cachedEncoder = nil
  }

  #if DEBUG
  /// Test seams for the warm-resource guarantees (latency plan, W3/W5). The encoder is the
  /// expensive half of what stays warm, and nothing else can observe whether it is still resident.
  var hasWarmEncoder: Bool { cachedEncoder != nil }
  var hasCachedSource: Bool { cachedSource != nil }
  func cacheSourceForTesting() {
    cachedSource = ("test", .init(hidden: .init(values: [], frames: 0, width: 0), rows: [], duration: 0))
  }
  /// Fails inside the encoder scope exactly where a real job can fail — the acoustics themselves
  /// need speech audio no fixture has, so this is how the guard above is exercised.
  func failInsideTheEncoderScope(directory: URL) throws {
    try withEncoder(directory: directory) { _ in throw BuddyError.invalidOutput }
  }
  #endif

  /// Reject an unsupported target before scoring; acoustics may already be cached or computed.
  /// Encoder support and vowel-head grading coverage are separate capabilities.
  static func validateTargets(_ words: [PronunciationWordTarget], vocabulary: [String: Int]) throws {
    for word in words {
      let supported = word.variants.contains { ipa in
        guard let units = UKPhoneInventory.parse(ipa) else { return false }
        return units.allSatisfy { UKPhoneInventory.ctcTokens($0.symbol, vocabulary: vocabulary) != nil }
      }
      guard supported else { throw UKReferenceError.wordPhones(word.text) }
    }
  }

  /// Older lessons may not have word timestamps. Align their complete UK phone
  /// path locally; store inferred boundaries in this result, without editing the
  /// lesson or changing the saved recording target.
  private static func anchor(_ words: [PronunciationWordTarget], source: Acoustic,
    sourceSpan: AudioSpan, vocabulary: [String: Int]) throws -> [PronunciationWordTarget] {
    if words.allSatisfy({ $0.sourceStart != nil && $0.sourceEnd != nil }) { return words }
    let sequences = try words.map { word -> [Int] in
      for variant in word.variants {
        guard let units = UKPhoneInventory.parse(variant) else { continue }
        let encoded = units.map { UKPhoneInventory.ctcTokens($0.symbol, vocabulary: vocabulary) }
        if encoded.allSatisfy({ $0 != nil }) { return encoded.compactMap { $0 }.flatMap { $0 } }
      }
      throw UKReferenceError.wordPhones(word.text)
    }
    let labels = sequences.flatMap { $0 }
    guard labels.count <= 512, let spans = try CTCAlignment.align(logProbabilities: source.rows, labels: labels) else { throw UKReferenceError.alignment }
    var cursor = 0
    return zip(words, sequences).map { word, sequence in
      defer { cursor += sequence.count }
      return .init(id: word.id, text: word.text, variants: word.variants,
        dictionarySources: word.dictionarySources,
        sourceStart: sourceSpan.start+Double(spans[cursor].start)*0.02,
        sourceEnd: sourceSpan.start+min(source.duration, Double(spans[cursor+sequence.count-1].end)*0.02))
    }
  }

  private static func infer(_ url: URL, span: AudioSpan?, session: ORTSession) throws -> Acoustic {
    let raw = try UKAudioInput.samples(url, span: span)
    let mean = raw.reduce(0.0) { $0+Double($1) }/Double(raw.count)
    let variance = raw.reduce(0.0) { $0+pow(Double($1)-mean,2) }/Double(raw.count)
    guard variance > 1e-8 else { throw BuddyError.noSpeech }
    let samples = raw.map { Float((Double($0)-mean)/sqrt(variance+1e-7)) }
    let bytes = samples.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let input = try ORTValue(tensorData: bytes, elementType: .float, shape: [1, NSNumber(value: samples.count)])
    let output = try session.run(withInputs: ["samples": input], outputNames: ["hidden", "logits"], runOptions: nil)
    try Task.checkCancellation()
    guard let hidden = output["hidden"], let logits = output["logits"] else { throw BuddyError.invalidOutput }
    let h = try matrix(hidden, width: 1024), l = try matrix(logits, width: 392)
    guard h.frames == l.frames else { throw BuddyError.invalidOutput }
    return .init(hidden: h, rows: try UKReferenceMath.logProbabilities(l), duration: Double(raw.count)/16000)
  }
  #if DEBUG
  static func encoderFixture(_ url: URL, directory: URL) throws -> (hidden: [Float], logp: [Float], frames: Int) {
    let environment = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2)
    let session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent("encoder.onnx").path, sessionOptions: options)
    let result = try infer(url, span: nil, session: session)
    return (result.hidden.values, result.rows.flatMap { $0 }, result.hidden.frames)
  }
  #endif

  private static func matrix(_ value: ORTValue, width: Int) throws -> UKReferenceMath.Matrix {
    let shape = try value.tensorTypeAndShapeInfo().shape
    guard shape.count == 3, shape[0].intValue == 1, shape[2].intValue == width,
      shape[1].intValue > 0, shape[1].intValue <= 1600 else { throw BuddyError.invalidOutput }
    let bytes = try value.tensorData() as Data
    guard bytes.count == shape[1].intValue*width*4 else { throw BuddyError.invalidOutput }
    let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard values.allSatisfy(\.isFinite) else { throw BuddyError.invalidOutput }
    return .init(values: values, frames: shape[1].intValue, width: width)
  }
}

enum UKReferenceError: Error, LocalizedError {
  case accent, wordTiming, phones, alignment
  case wordPhones(String), wordAlignment(String)
  var word: String? {
    switch self {
    case .wordPhones(let text), .wordAlignment(let text): text
    default: nil
    }
  }
  var errorDescription: String? {
    switch self {
    case .accent: "assessment.uk.error.accent"
    case .wordTiming: "assessment.uk.error.timing"
    case .phones: "assessment.uk.error.phones"
    case .alignment: "assessment.uk.error.alignment"
    case .wordPhones: "assessment.uk.error.word_phones"
    case .wordAlignment: "assessment.uk.error.word_alignment"
    }
  }
}
