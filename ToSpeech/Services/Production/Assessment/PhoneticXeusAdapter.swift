import Foundation
import OSLog
import Darwin

/// How much of the assessment pipeline may stay warm between jobs. The XEUS helper holds ~4.6 GB
/// and the UK encoder session ~1.5 GB; a small machine cannot afford both, so it keeps nothing
/// warm and runs the two branches in turn instead of overlapping them.
enum AssessmentResourcePolicy: Sendable, Equatable {
  case warmParallel, coldSequential
  static func current(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Self {
    physicalMemory < 12*1024*1024*1024 ? .coldSequential : .warmParallel
  }
  var idleTimeout: Duration { self == .warmParallel ? .seconds(600) : .zero }
  var overlapsBranches: Bool { self == .warmParallel }
}

/// Measurement only (latency plan, task 5): one `STAGE <name> <seconds>` line per pipeline stage at
/// info level, and — when this process is the pronunciation probe — the same line on stdout, so a
/// breakdown can be read from the probe log as well as the unified log. It decides nothing.
enum AssessmentStage {
  private static let logger = Logger(subsystem: "com.unknownstudio.tospeech", category: "AssessmentStage")
  /// The probe runs the app binary directly; `print` keeps the breakdown in its captured stdout.
  static let isProbe = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--pronunciation-probe") }
  static func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)*1e-18
  }
  static func log(_ name: String, since start: ContinuousClock.Instant, _ detail: String = "") {
    log(name, seconds: seconds(since: start), detail)
  }
  static func log(_ name: String, seconds: Double, _ detail: String = "") {
    let line = "STAGE \(name) \(String(format: "%.4f", seconds))"+(detail.isEmpty ? "" : " "+detail)
    logger.info("\(line, privacy: .public)")
    if isProbe { print(line) }
  }
}

actor PhoneticXeusAdapter: PhoneScoring {
  let package: PhoneticXeusPackage
  let ukPackage: UKReferencePackage
  private let policy: AssessmentResourcePolicy
  /// One UK adapter for the life of the app: it owns the cached source acoustics and encoder, and
  /// the app shares the very same instance with the UK Reference engine — two warm encoder sessions
  /// are ~1.5 GB each and nothing here needs a second one.
  let ukAdapter: UKReferenceAdapter
  private let logger = Logger(subsystem: "com.unknownstudio.tospeech", category: "PhoneticXeus")
  /// The native scorer memory-maps `xeus.onnx.data` (2.3 GB), so it is built once per install
  /// directory and kept warm between jobs; `release()` drops it.
  private var scorer: XeusOnnxScorer?
  /// An injected adapter belongs to the service, which releases it when neither engine needs it; one
  /// built here has no other owner, so `release()` has to drop it too.
  private let ownsUKAdapter: Bool
  private init(package: PhoneticXeusPackage, ukPackage: UKReferencePackage, ukAdapter: UKReferenceAdapter,
    policy: AssessmentResourcePolicy, ownsUKAdapter: Bool) {
    self.package = package; self.ukPackage = ukPackage; self.policy = policy
    self.ukAdapter = ukAdapter; self.ownsUKAdapter = ownsUKAdapter
  }
  init(package: PhoneticXeusPackage, ukPackage: UKReferencePackage, ukAdapter: UKReferenceAdapter,
    policy: AssessmentResourcePolicy = .current()) {
    self.init(package: package, ukPackage: ukPackage, ukAdapter: ukAdapter, policy: policy,
      ownsUKAdapter: false)
  }
  /// For callers with no UK engine of their own: this adapter builds the one it needs, and owns it.
  init(package: PhoneticXeusPackage, ukPackage: UKReferencePackage,
    policy: AssessmentResourcePolicy = .current()) {
    self.init(package: package, ukPackage: ukPackage,
      ukAdapter: UKReferenceAdapter(package: ukPackage, idleTimeout: policy.idleTimeout), policy: policy,
      ownsUKAdapter: true)
  }
  func assess(sourceURL: URL, sourceSpan: AudioSpan, takeURL: URL,
    words: [PronunciationWordTarget], accent: ReferenceAccent) async throws -> PronunciationEvidence {
    guard accent == .uk else { throw UKReferenceError.accent }
    guard !words.isEmpty, words.count <= 128 else { throw BuddyError.tooLong }
    let directory = try await package.validate()
    let ukDirectory = try await ukPackage.validate()
    var mark = ContinuousClock.now
    let vad = try UKVoiceActivity.analyze(sourceURL: sourceURL, span: sourceSpan, takeURL: takeURL, directory: ukDirectory)
    AssessmentStage.log("xeus.vad", since: mark)
    guard !vad.take.isEmpty, !vad.source.isEmpty else { throw BuddyError.noSpeech }
    mark = .now
    let sourceSamples = try UKAudioInput.samples(sourceURL, span: sourceSpan)
    let takeSamples = try UKAudioInput.samples(takeURL, span: nil)
    AssessmentStage.log("xeus.pcm", since: mark)
    // Everything that can reject this job is decided before the UK branch starts: an unsupported
    // target used to throw with the warm Task already running, which cancelled it mid-encoder.
    let request = XeusRequest(words: try words.map { word in
      let variants = word.variants.compactMap { UKPhoneInventory.parse($0)?.map(\.symbol) }
      guard !variants.isEmpty else { throw PhoneticXeusError.target(word.text) }
      return .init(id: word.id, text: word.text, variants: variants)
    })
    // The delivery branch reads the same audio with its own encoder. Nothing it computes depends
    // on the scorer, so it runs alongside it and only the variant choice waits for XEUS.
    let warm = policy.overlapsBranches ? Task { [ukAdapter] in
      try await ukAdapter.acoustics(sourceURL: sourceURL, sourceSpan: sourceSpan, takeURL: takeURL)
    } : nil
    defer { warm?.cancel() }
    mark = .now
    // The native scorer throws (never traps) on a malformed assessment; an unsupported target that
    // slips past the parse check above surfaces as PhoneticXeusError.target, mirroring the old path.
    var raw: PhoneticXeusEvidence
    do {
      raw = try await scorer(directory: directory).evidence(
        source: sourceSamples, take: takeSamples, request: request,
        sourceDuration: Double(sourceSamples.count) / 16000, takeDuration: Double(takeSamples.count) / 16000)
    } catch let error as XeusRuntimeError {
      if case .unsupportedUKTarget(let word) = error { throw PhoneticXeusError.target(word) }
      throw PhoneticXeusError.invalidEvidence
    }
    AssessmentStage.log("xeus.scorer.run", since: mark)
    mark = .now
    // The native port does not emit the reference-diagnostics block (reference.py's DTW/JSD layer is
    // out of scope), so its validation is skipped here — no per-phone status/reason/coverage depends
    // on it.
    let assessed = try Self.convert(raw, targets: words, requireDiagnostics: false)
    AssessmentStage.log("xeus.convert", since: mark)
    var evidence = PronunciationEvidence(words: assessed, duration: raw.duration, recognizedPhones: raw.recognizedPhones,
      qualityPolicy: raw.policy)
    // These heads need XLSR features. Only delivery measurements are carried over;
    // the old nine-vowel decisions never participate in XEUS phone coloring.
    do {
      let targets = zip(words, assessed).map { word, result in
        PronunciationWordTarget(id: word.id, text: word.text, variants: [result.referenceIPA!],
          dictionarySources: word.dictionarySources, sourceStart: word.sourceStart, sourceEnd: word.sourceEnd)
      }
      let acoustics: UKAcoustics
      if let warm { acoustics = try await warm.value }
      else { acoustics = try await ukAdapter.acoustics(sourceURL: sourceURL, sourceSpan: sourceSpan, takeURL: takeURL) }
      let delivery = try await ukAdapter.score(acoustics, words: targets)
      evidence.ukReference = delivery.ukReference
    } catch is CancellationError { throw CancellationError() }
    catch {
      raw.deliveryError = error.localizedDescription
      logger.error("UK delivery branch: \(error.localizedDescription, privacy: .public)")
    }
    evidence.phoneticXeus = raw
    return evidence
  }
  /// Spec L4: the helper (~4.6 GB) is released when the user switches to another engine, not only
  /// after the idle timeout. The session object is kept so a degraded daemon stays degraded; it
  /// restarts lazily on the next job. An injected UK adapter is shared with the UK Reference engine,
  /// which may be the very engine being switched to, so its encoder is released by the service
  /// instead; one this adapter built for itself is released here.
  func release() async {
    scorer = nil
    if ownsUKAdapter { await ukAdapter.release() }
  }
  /// The scorer memory-maps the ONNX external data and keeps it warm between jobs; it is built on the
  /// first assessment for the validated install directory.
  private func scorer(directory: URL) throws -> XeusOnnxScorer {
    if let scorer { return scorer }
    let scorer = try XeusOnnxScorer(directory: directory)
    self.scorer = scorer
    return scorer
  }
  static let licences: Set<String> = ["accepted", "classD", "head", "weak", "unmapped", "cannotDistinguish"]
  /// Display policy over the helper's verdicts. Yellow only for a take that matches the reference realization
  /// with a positive but sub-threshold margin, or an ambiguous contrast-head decision. Never from low confidence alone.
  static func quality(_ phone: PhoneticXeusPhoneEvidence) -> PronunciationQuality {
    switch phone.status {
    case "correct": return .correct
    case "likelyIncorrect": return .incorrect
    default:
      // The contrast block is written before the reference gate runs, so a row can carry an
      // ambiguous head decision and still have been demoted to referenceWeak/referenceUnmapped/
      // modelCannotDistinguish. Only a row whose final reason is still `ambiguous` may go yellow.
      if phone.contrast?.decision == "ambiguous", phone.reason == "ambiguous" { return .nearCorrect }
      if phone.referenceMatch == true, phone.takeStatus == "uncertain", phone.reason == "ambiguous",
        let margin = phone.logMargin, margin > 0, margin < Darwin.log(4) { return .nearCorrect }
      return .unassessed
    }
  }
  static func reason(_ phone: PhoneticXeusPhoneEvidence) -> PhoneAssessmentAvailability {
    switch phone.reason {
    case "referenceUnmapped": .referenceUnmapped
    case "referenceWeak": .referenceWeak
    case "referenceNotConfident": .referenceNotConfident
    case "modelCannotDistinguish": .modelCannotDistinguish
    case "ambiguousSubstitution": .ambiguousSubstitution
    case "referenceUncertain": .referenceUncertain
    default: .takeUncertain
    }
  }
  static func convert(_ raw: PhoneticXeusEvidence, targets: [PronunciationWordTarget],
    requireDiagnostics: Bool = true) throws -> [WordPronunciationEvidence] {
    guard raw.revision == PhoneticXeusPackage.revision, raw.policy == PhoneticXeusPackage.evidencePolicy,
      raw.mapping == PhoneticXeusPackage.mappingPolicy, raw.dtype == "float32", raw.device == "cpu",
      raw.duration.isFinite, raw.duration > 0, raw.duration <= 30,
      raw.sourceDuration.isFinite, raw.sourceDuration > 0, raw.sourceDuration <= 30,
      raw.words.map(\.id) == targets.map(\.id), raw.sourceShape.count == 2, raw.takeShape.count == 2,
      (1...1600).contains(raw.sourceShape[0]), (1...1600).contains(raw.takeShape[0]),
      raw.sourceShape[1] == 428, raw.takeShape[1] == 428 else { throw PhoneticXeusError.invalidEvidence }
    if requireDiagnostics { try raw.validateReferenceDiagnostics() }
    var previousTakeEnd = 0.0, previousSourceEnd = 0.0
    var previousUnitID: String?
    var previousTake: (start: Double?, end: Double?) = (nil, nil)
    var previousSource: (start: Double?, end: Double?) = (nil, nil)
    return try zip(raw.words, targets).map { row, target in
      guard let ipa = target.variants.first(where: { UKPhoneInventory.parse($0)?.map(\.symbol) == row.variant }),
        row.phones.map(\.expected) == row.variant else { throw PhoneticXeusError.invalidEvidence }
      let phones = try row.phones.enumerated().map { index, phone -> PhoneDifference in
        guard ["correct", "likelyIncorrect", "uncertain", "unavailable"].contains(phone.status),
          phone.expectedProbability.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
          phone.expectedTokenProbability.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
          phone.logMargin.map(\.isFinite) ?? true,
          phone.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw PhoneticXeusError.invalidEvidence }
        let graded = phone.status == "correct" || phone.status == "likelyIncorrect"
        let licensed = phone.sourceStatus == "correct" || ["classD", "head"].contains(phone.licence ?? "")
        guard !graded || (licensed && phone.expectedProbability != nil && phone.logMargin != nil) else { throw PhoneticXeusError.invalidEvidence }
        if let licence = phone.licence { guard Self.licences.contains(licence) else { throw PhoneticXeusError.invalidEvidence } }
        if let contrast = phone.contrast {
          guard contrast.pUK.isFinite, (0...1).contains(contrast.pUK), ["uk", "us", "ambiguous"].contains(contrast.decision), !contrast.name.isEmpty else { throw PhoneticXeusError.invalidEvidence }
        }
        // A PAIRS unit (/ə ɹ/ in "around") is one licensed sound shown as two display phones: the
        // helper emits the same row twice, so both members carry identical spans on both timelines.
        // That is one sound, not two out of order — require the spans to match exactly and leave the
        // cursor where it was, so the next real sound is still compared against the unit's end.
        let sameUnit = phone.unitID != nil && phone.unitID == previousUnitID
        if sameUnit {
          guard phone.start == previousTake.start, phone.end == previousTake.end,
            phone.sourceStart == previousSource.start,
            phone.sourceEnd == previousSource.end else { throw PhoneticXeusError.invalidEvidence }
        }
        if let start = phone.start, let end = phone.end {
          guard start.isFinite, end.isFinite, end > start, end <= raw.duration else { throw PhoneticXeusError.invalidEvidence }
          if !sameUnit {
            guard start >= previousTakeEnd else { throw PhoneticXeusError.invalidEvidence }
            previousTakeEnd = end
          }
        } else if graded || phone.start != nil || phone.end != nil { throw PhoneticXeusError.invalidEvidence }
        if let start = phone.sourceStart, let end = phone.sourceEnd {
          guard start.isFinite, end.isFinite, end > start, end <= raw.sourceDuration else { throw PhoneticXeusError.invalidEvidence }
          if !sameUnit {
            guard start >= previousSourceEnd else { throw PhoneticXeusError.invalidEvidence }
            previousSourceEnd = end
          }
        } else if graded || phone.sourceStart != nil || phone.sourceEnd != nil { throw PhoneticXeusError.invalidEvidence }
        previousUnitID = phone.unitID
        previousTake = (phone.start, phone.end)
        previousSource = (phone.sourceStart, phone.sourceEnd)
        let quality = Self.quality(phone)
        let kind: PhoneDifference.Kind = quality == .correct ? .matched : quality == .incorrect ? .substitution
          : quality == .nearCorrect ? .scored : .uncertain
        return PhoneDifference(id: index, kind: kind, expected: phone.expected,
          observed: quality == .correct ? phone.expected : phone.closestPhone, start: phone.start, end: phone.end,
          quality: quality, unassessedReason: quality != .unassessed ? nil : Self.reason(phone))
      }
      return WordPronunciationEvidence(target: target, referenceIPA: ipa, phones: phones, supported: true, inventory: UKPhoneInventory.version)
    }
  }
}
