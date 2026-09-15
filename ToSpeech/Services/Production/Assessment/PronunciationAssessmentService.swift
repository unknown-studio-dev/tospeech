import Foundation
import Observation
import OSLog

@MainActor @Observable
final class PronunciationAssessmentService {
  private let database: ProductionDatabase
  private let paths: BackendPaths
  private let dictionary: OfflineIPADictionary?
  private let adapter: any PronunciationRecognizing
  private let scorer: (any PhoneScoring)?
  private let ukScorer: (any PhoneScoring)?
  private let xeusScorer: (any PhoneScoring)?
  private let ukG2P: UKG2P?
  private let delivery = AcousticDeliveryAnalyzer()
  private var worker: Task<Void, Never>?
  private(set) var jobs: [PronunciationJob] = []
  private(set) var error: String?
  private(set) var isProcessing = false
  var practiceIsBusy: @MainActor () -> Bool = { false }

  init(database: ProductionDatabase, paths: BackendPaths, dictionary: OfflineIPADictionary?, adapter: any PronunciationRecognizing, scorer: (any PhoneScoring)? = nil, ukScorer: (any PhoneScoring)? = nil, ukG2P: UKG2P? = nil, xeusScorer: (any PhoneScoring)? = nil) {
    self.database = database; self.paths = paths; self.dictionary = dictionary; self.adapter = adapter; self.scorer = scorer; self.ukScorer = ukScorer; self.ukG2P = ukG2P; self.xeusScorer = xeusScorer
  }
  func history(takeID: UUID) -> [PronunciationJob] { jobs.filter { $0.takeID == takeID } }

  func enqueue(_ take: ProductionStoredTake, preferences: Preferences, force: Bool = false) async {
    guard let engine = preferences.productionAssessmentEngine, [.buddy, .phone, .ukReference, .phoneticXeus].contains(engine), take.status == "ready",
      [.complete, .earlyStop].contains(take.outcome) else { return }
    await releaseWarmEnginesIfChanged(to: engine)
    do {
      guard let sentence = try await database.savedTakeSentences(lessonID: take.lessonID, paths: paths)[take.id] else {
        throw ProductionPracticeError.invalidTarget
      }
      var words: [PronunciationWordTarget] = []
      for token in sentence.tokens where sentence.target.scope != .phrase || sentence.target.wordIDs.contains(token.id) {
        if [.ukReference, .phoneticXeus].contains(engine), !IPAFormatting.isPronounceable(token.text) { continue }
        var pronunciations: [OfflineIPAPronunciation] = []
        if let override = sentence.ipaOverride(for: token, accent: preferences.accent) {
          pronunciations = override
        } else if let dictionary {
          for accent in (engine != .buddy ? [preferences.accent] : [preferences.accent, preferences.accent == .uk ? .us : .uk]) {
            pronunciations += try await dictionary.pronunciations(for: token.text, accent: accent)
          }
        }
        words.append(PronunciationWordTarget(id: token.id, text: token.text,
          variants: pronunciations.map(\.ipa),
          dictionarySources: Array(Set(pronunciations.map { "\($0.source)@\($0.sourceRevision)" })).sorted(),
          sourceStart: token.startFrame.map { Double($0)/Double(sentence.target.sampleRate) },
          sourceEnd: token.endFrame.map { Double($0)/Double(sentence.target.sampleRate) }))
      }
      if [.ukReference, .phoneticXeus].contains(engine), let ukG2P {
        let missing = words.filter { $0.variants.isEmpty }.map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
        let generated = try await ukG2P.pronunciations(missing)
        words = words.map { word in
          guard word.variants.isEmpty,
            let entry = generated[word.text.trimmingCharacters(in: .punctuationCharacters)] else { return word }
          return .init(id: word.id, text: word.text, variants: [entry.ipa],
            dictionarySources: ["\(entry.source)@\(entry.sourceRevision)"], sourceStart: word.sourceStart, sourceEnd: word.sourceEnd)
        }
      }
      _ = try await database.enqueuePronunciation(takeID: take.id, words: words, accent: preferences.accent,
        provenance: engine == .phoneticXeus ? PhoneticXeusPackage.provenance : engine == .ukReference ? UKReferencePackage.provenance : engine == .phone ? PhoneScorerPackage.provenance : BuddyModelPackage.provenance, force: force)
      error = nil
      await recover()
    } catch { report(error) }
  }

  /// Spec L4: the XEUS helper process (~4.6 GB) and the UK encoder session (~1.5 GB) stay warm
  /// between jobs, so a user who moves to another engine would otherwise keep ~6 GB resident for
  /// nothing. Each is released only once its own engine is out of the picture — the UK encoder is
  /// shared with XEUS, so moving between those two keeps it — and never while that engine still has
  /// work in flight: tearing a live request down only restarts the helper.
  private func releaseWarmEnginesIfChanged(to engine: EngineID) async {
    guard !isProcessing else { return }
    let xeusPending = jobs.contains { $0.provenance == PhoneticXeusPackage.provenance && $0.isPending }
    if engine != .phoneticXeus, let xeusScorer, !xeusPending { await xeusScorer.release() }
    // XEUS scores delivery through the same UK adapter, so its encoder is idle only once neither
    // engine has work left.
    if engine != .phoneticXeus, engine != .ukReference, let ukScorer, !xeusPending,
      !jobs.contains(where: { $0.provenance == UKReferencePackage.provenance && $0.isPending }) {
      await ukScorer.release()
    }
  }

  func retry(_ job: PronunciationJob) async {
    do {
      _ = try await database.enqueuePronunciation(takeID: job.takeID, words: job.words, accent: job.accent,
        provenance: Self.retryProvenance(job.provenance), force: true)
      await recover()
    } catch { report(error) }
  }

  /// Retry creates a new result under the current runtime of the SAME engine.
  /// Never label newly computed evidence with a historical helper's identity.
  nonisolated static func retryProvenance(_ previous: String) -> String {
    if previous.hasPrefix("PhoneticXeus · ") { return PhoneticXeusPackage.provenance }
    if previous.hasPrefix("UK Reference · ") { return UKReferencePackage.provenance }
    return previous
  }

  func recover() async {
    error = nil
    await reload()
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      defer { self.worker = nil; self.isProcessing = false }
      while !Task.isCancelled {
        await self.reload()
        guard var job = self.jobs.first(where: \.isPending) else { return }
        if self.practiceIsBusy() {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          continue
        }
        self.isProcessing = true
        let jobMark = ContinuousClock.now
        do {
          guard [BuddyModelPackage.provenance, PhoneScorerPackage.provenance, UKReferencePackage.provenance, PhoneticXeusPackage.provenance].contains(job.provenance) else { throw BuddyError.modelMissing }
          job.status = .running
          job.error = nil
          job.errorWord = nil
          try await self.database.updatePronunciation(job)
          await self.reload()
          let url = self.paths.finalTakes.appendingPathComponent("\(job.takeID.uuidString).caf")
          let checksum = try await Task.detached(priority: .utility) { try BuddyModelPackage.checksum(url) }.value
          guard checksum == job.audioChecksum else { throw BuddyError.checksum }
          guard let source = try await self.database.savedTakeSentences(lessonID: job.target.lessonID, paths: self.paths)[job.takeID],
            source.target.snapshot == job.target, let sourceChecksum = job.sourceAudioChecksum else { throw BuddyError.invalidAudio }
          let sourceURL = source.target.audioURL
          let currentSourceChecksum = try await Task.detached(priority: .utility) { try BuddyModelPackage.checksum(sourceURL) }.value
          guard currentSourceChecksum == sourceChecksum else { throw BuddyError.checksum }
          if job.provenance == PhoneScorerPackage.provenance || job.provenance == UKReferencePackage.provenance || job.provenance == PhoneticXeusPackage.provenance {
            guard let scorer = job.provenance == PhoneticXeusPackage.provenance ? self.xeusScorer : job.provenance == UKReferencePackage.provenance ? self.ukScorer : self.scorer else { throw PhoneScorerError.packageMissing }
            job.result = try await scorer.assess(sourceURL: sourceURL,
              sourceSpan: AudioSpan(start: Double(job.target.startFrame)/Double(job.target.sampleRate),
                end: Double(job.target.endFrame)/Double(job.target.sampleRate)),
              takeURL: url, words: job.words, accent: job.accent)
          } else {
          let reference = try await self.adapter.recognize(audioURL: sourceURL,
            span: AudioSpan(start: Double(job.target.startFrame)/Double(job.target.sampleRate),
              end: Double(job.target.endFrame)/Double(job.target.sampleRate)))
          let output = try await self.adapter.recognize(audioURL: url, span: nil)
          let targets = job.words
          job.result = try await Task.detached(priority: .utility) {
            let learner = try PronunciationComparison.compare(targets: targets, heard: output.phones, duration: output.duration)
            let source = try PronunciationComparison.compare(targets: targets, heard: reference.phones, duration: reference.duration)
            return PronunciationComparison.gate(learner, reference: source)
          }.value
          }
          if var result = job.result {
            result.audioDecodingPolicy = "av-foundation-full-clip-v2"
            let deliveryMark = ContinuousClock.now
            do {
              result.delivery = try await self.delivery.analyze(sourceURL: sourceURL,
                span: AudioSpan(start: Double(job.target.startFrame)/Double(job.target.sampleRate),
                  end: Double(job.target.endFrame)/Double(job.target.sampleRate)),
                takeURL: url, pronunciation: result)
            } catch {
              result.delivery = DeliveryEvidence(source: nil, take: nil, error: error.localizedDescription)
              Logger(subsystem: "com.unknownstudio.tospeech", category: "Pronunciation")
                .error("Delivery analysis: \(error.localizedDescription, privacy: .public)")
            }
            AssessmentStage.log("service.delivery", since: deliveryMark)
            job.result = result
          }
          job.status = .complete
          job.error = nil
        } catch BuddyError.noSpeech {
          job.status = .unrecognized
          job.error = "assessment.error.no_speech"
        } catch {
          job.status = .failed
          job.error = error.localizedDescription
          job.errorWord = (error as? UKReferenceError)?.word
          Logger(subsystem: "com.unknownstudio.tospeech", category: "Pronunciation")
            .error("Assessment job \(job.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public); word=\(job.errorWord ?? "—", privacy: .public)")
        }
        self.isProcessing = false
        let dbMark = ContinuousClock.now
        do { try await self.database.updatePronunciation(job) }
        catch {
          await self.reload()
          if !self.jobs.contains(where: { $0.id == job.id }) { continue }
          self.report(error)
          return
        }
        AssessmentStage.log("service.db", since: dbMark)
        AssessmentStage.log("service.job", since: jobMark)
      }
    }
  }

  private func reload() async {
    do { jobs = try await database.pronunciationJobs() }
    catch { report(error) }
  }
  private func report(_ failure: any Error) {
    error = failure.localizedDescription
    Logger(subsystem: "com.unknownstudio.tospeech", category: "Pronunciation").error("Assessment: \(failure.localizedDescription, privacy: .public)")
  }
}
