import Foundation
import Testing
@testable import ToSpeech

@Suite struct UKReferenceTests {
  @Test func britfoneSquareIsOneNucleusAndHistoricalColorsStayReadable() throws {
    let ipa = "wˈɛə"
    let current = try #require(UKPhoneInventory.parse(ipa))
    #expect(current.map(\.symbol) == ["w", "ɛə"])
    #expect(current.filter(\.isNucleus).count == 1)
    #expect(current.last?.stress == 1)
    #expect(UKPhoneInventory.ctcTokens("ɛə", vocabulary: ["eə":7]) == [7])
    for version in ["uk-ipa-v1", UKPhoneInventory.version] {
      let units = try #require(UKPhoneInventory.parse(ipa, inventory: version))
      #expect(units.count == (version == "uk-ipa-v1" ? 3 : 2))
      let target = PronunciationWordTarget(id: "where", text: "where", variants: [ipa], dictionarySources: [], sourceStart: nil, sourceEnd: nil)
      let phones = units.enumerated().map { i,unit in
        PhoneDifference(id: i, kind: .matched, expected: unit.symbol, observed: unit.symbol, start: nil, end: nil, quality: .correct)
      }
      let word = WordPronunciationEvidence(target: target, referenceIPA: ipa, phones: phones, supported: true, inventory: version)
      let runs = PronunciationDisplay.runs(ipa: ipa, word: word)
      #expect(runs.map(\.text).joined() == "/wˈɛə/")
      #expect(runs.filter { $0.quality == .correct }.count == units.count)
    }
  }
  @Test func inventoryPreservesUKContrastsLengthAndStress() throws {
    let units = try #require(UKPhoneInventory.parse("/ˈkɑːt kɒt ˌnɜːs ɡəʊ/"))
    #expect(units.map(\.symbol) == ["k","ɑː","t","k","ɒ","t","n","ɜː","s","ɡ","əʊ"])
    #expect(units[1].stress == 1 && units[7].stress == 2)
    #expect(UKPhoneInventory.canonical("ɒ") != UKPhoneInventory.canonical("ɑː"))
    #expect(UKPhoneInventory.canonical("əʊ") != "oʊ")
    #expect(UKPhoneInventory.parse("/nɜː☃s/") == nil)
  }
  @Test func tokenizerRejectsMissingPhonesRatherThanUSSubstitution() {
    #expect(UKPhoneInventory.ctcTokens("ɒ", vocabulary: ["ɑː":1]) == nil)
    #expect(UKPhoneInventory.ctcTokens("ɪə", vocabulary: ["ɪ":1,"ə":2]) == [1,2])
    #expect(UKPhoneInventory.ctcTokens("ɜː", vocabulary: ["ɚ":1]) == nil)
  }
  @Test func UKDisplayKeepsLengthAttachedToAssessedUnitAndStressNeutral() {
    let word = WordPronunciationEvidence(target: .init(id: "x", text: "nurse", variants: ["ˈnɜːs"], dictionarySources: [], sourceStart: 0, sourceEnd: 1),
      referenceIPA: "ˈnɜːs", phones: [
        .init(id: 0, kind: .scored, expected: "n", observed: nil, start: 0, end: 0.2, quality: .unassessed),
        .init(id: 1, kind: .scored, expected: "ɜː", observed: "ɜː", start: 0.2, end: 0.7, quality: .correct),
        .init(id: 2, kind: .scored, expected: "s", observed: nil, start: 0.7, end: 1, quality: .unassessed)
      ], supported: true, inventory: UKPhoneInventory.version)
    let runs = PronunciationDisplay.runs(ipa: word.referenceIPA, word: word)
    #expect(runs.first { $0.text == "ɜː" }?.quality == .correct)
    #expect(runs.first { $0.text == "ˈ" }?.quality == .unassessed)
  }
  @Test func distancesAreNotInventedForInvalidOrSilentVectors() {
    #expect(UKReferenceMath.cosineDistance([0,0],[1,2]) == nil)
    #expect(UKReferenceMath.cosineDistance([.nan,1],[1,2]) == nil)
    #expect(abs((UKReferenceMath.cosineDistance([1,2],[2,4]) ?? 1)) < 1e-10)
  }
  @Test func ctcRegionsRejectOverlapAndNeverCrossWord() {
    #expect(UKReferenceMath.regions([.init(start: 2,end: 5),.init(start: 4,end: 6)], lower: 0, upper: 10).isEmpty)
    let regions = UKReferenceMath.regions([.init(start: 2,end: 3),.init(start: 5,end: 6)], lower: 1, upper: 8)
    #expect(regions == [.init(start: 1,end: 4),.init(start: 4,end: 8)])
  }
  @Test func oldEvidenceRemainsReadableWithoutUKFields() throws {
    let json = #"{"words":[],"duration":1,"recognizedPhones":[]}"#
    let evidence = try JSONDecoder().decode(PronunciationEvidence.self, from: Data(json.utf8))
    #expect(evidence.ukReference == nil && evidence.delivery == nil)
    let word = #"{"target":{"id":"x","text":"test","variants":[],"dictionarySources":[]},"phones":[],"supported":false}"#
    #expect(try JSONDecoder().decode(WordPronunciationEvidence.self, from: Data(word.utf8)).inventory == nil)
  }
  @Test func classifierMatchesStableMulticlassAndBinaryMath() throws {
    let h = UKVowelHead(labels: ["ɒ","ɑː"], mean: [0,0], scale: [1,1], weights: [[0,0],[1,0]], bias: [0,0], confidenceFloor: 0.8, policy: "test")
    #expect(h.predict([10,0])?.symbol == "ɑː")
    #expect(h.predict([.nan,0]) == nil)
    let binary = UKVowelHead(labels: ["0","1"], mean: [0], scale: [1], weights: [[1]], bias: [0], confidenceFloor: 0.8, policy: "test")
    #expect(abs((binary.probabilities([0])?.last ?? 0)-0.5)<1e-12)
  }
}

@Suite struct UKPitchAndGenerationTests {
  @Test func generatedUKIPAPreservesDiphthongAndTrap() {
    #expect(UKG2P.normalized(" ʃ_ˈa_d_əʊ_ɪ_ŋ\n") == "ʃˈædəʊɪŋ")
    #expect(UKG2P.normalized("t_ˈaɪ_m") == "tˈaɪm")
    #expect(UKPhoneInventory.parse(UKG2P.normalized("n_ˈɜː_s"))?.map(\.symbol) == ["n","ɜː","s"])
    // en-us output follows the ipa-dict style: /ɝ/ for NURSE, no length marks.
    #expect(UKG2P.normalizedUS("n_ˈɜː_s\n") == "nˈɝs")
    #expect(UKG2P.normalizedUS("t_ə_m_ˈeɪ_ɾ_oʊ") == "təmˈeɪɾoʊ")
  }
  @Test func modelPitchCentersEachVoiceAndDoesNotFillUnvoicedFrames() {
    let track = DeliveryTrack(duration: 0.1, frames: (0..<4).map {
      .init(time: (Double($0*256)+127.5)/16000, relativeDB: -3, pitchSemitones: 9)
    }, pauses: [], activeSpan: .init(start: 0, end: 0.1))
    let pitch = (0..<4).map { UKPitchFrame(time: track.frames[$0].time, hz: $0 == 0 ? 100 : 200, confidence: $0 == 3 ? 0.8 : 0.99) }
    let doubled = pitch.map { UKPitchFrame(time: $0.time, hz: $0.hz*2, confidence: $0.confidence) }
    let a = UKPitchEvidence.apply(pitch, to: track), b = UKPitchEvidence.apply(doubled, to: track)
    #expect(a.frames.map(\.pitchSemitones) == b.frames.map(\.pitchSemitones))
    #expect(a.frames[0].pitchSemitones == -12)
    #expect(a.frames[3].pitchSemitones == nil)
    #expect(UKPitchEvidence.apply([], to: track).pitchFrames == 0)
  }
  @Test func rejectsWrongAccentBeforeAccessingPackage() async throws {
    let paths = BackendPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let adapter = UKReferenceAdapter(package: UKReferencePackage(paths: paths, bundled: nil))
    do {
      _ = try await adapter.assess(sourceURL: paths.root, sourceSpan: .init(start: 0,end: 1), takeURL: paths.root, words: [], accent: .us)
      Issue.record("US request must not silently run the UK engine")
    } catch UKReferenceError.accent { } catch { Issue.record("Wrong error: \(error)") }
  }
  @Test func malformedHeadRejectsDimensionMismatchAndNonpositiveScale() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"labels":["a","b"],"mean":[0],"scale":[0],"weights":[[1]],"bias":[0],"confidenceFloor":0.8,"policy":"test"}"#
    try Data(json.utf8).write(to: root.appendingPathComponent("uk-vowels.json"))
    #expect(throws: (any Error).self) { try UKVowelHead.load(directory: root) }
  }
}

private final class UKPitchFixtureLocator: NSObject { }
@Suite struct UKModelRuntimeTests {
  @Test func bundledPitchGraphMatchesUpstreamAndRejectsWhiteNoise() throws {
    let fixtures = Bundle(for: UKPitchFixtureLocator.self)
    let source = try #require(fixtures.url(forResource: "harmonic-120", withExtension: "wav"))
    let noise = try #require(fixtures.url(forResource: "noise", withExtension: "wav"))
    let expectedURL = try #require(fixtures.url(forResource: "harmonic-120", withExtension: "json"))
    let expected = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: expectedURL))
    let hz = try #require(expected["hz"]), confidence = try #require(expected["confidence"])
    let directory = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    let actual = try UKPitchAdapter.analyze(sourceURL: source, span: .init(start: 0, end: 2), takeURL: noise, directory: directory)
    #expect(actual.source.count == hz.count && hz.count == 125)
    #expect(actual.source.filter(\.isVoiced).count == 125)
    #expect(actual.take.allSatisfy { !$0.isVoiced })
    for (i, frame) in actual.source.enumerated() {
      #expect(abs(frame.hz-hz[i]) < 0.001)
      #expect(abs(frame.confidence-confidence[i]) < 0.0001)
      #expect(abs(frame.time-(Double(i*256)+127.5)/16000) < 1e-10)
    }
  }
}

@Suite struct UKVADTests {
  @Test func speechSegmentationDoesNotAcceptIsolatedPeaksOrCountLeadingSilence() {
    #expect(UKVoiceActivity.segments([0,0,0.9,0,0,0,0], duration: 0.224).isEmpty)
    let spans = UKVoiceActivity.segments([0,0.9,0.9,0.9,0,0,0,0,0.8,0.8,0.8], duration: 0.35)
    #expect(spans == [.init(start: 0.032, end: 0.128), .init(start: 0.256, end: 0.35)])
    #expect(UKVoiceActivity.segments([], duration: 1).isEmpty)
  }
  @Test func bundledVADRejectsHarmonicToneEvenWhenPitchIsConfident() throws {
    let fixtures = Bundle(for: UKPitchFixtureLocator.self)
    let tone = try #require(fixtures.url(forResource: "harmonic-120", withExtension: "wav"))
    let noise = try #require(fixtures.url(forResource: "noise", withExtension: "wav"))
    let directory = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    let result = try UKVoiceActivity.analyze(sourceURL: tone, span: .init(start: 0,end: 2), takeURL: noise, directory: directory)
    #expect(result.source.isEmpty && result.take.isEmpty)
  }
}

@Suite struct UKVowelQualityTests {
  let labels = ["ɪ","ɛ","æ","ɒ","ɑː","əʊ"]
  @Test func confidenceIsNeverAmberAndSourceErrorsAreNotBlamedOnLearner() {
    let weak = UKReferenceQuality.decide(expected: "ɛ", supported: labels,
      source: .init(symbol: "ɛ", probability: 0.99), take: .init(symbol: "æ", probability: 0.6), floor: 0.8)
    #expect(weak.quality == .unassessed && weak.kind == .uncertain)
    let wrongSource = UKReferenceQuality.decide(expected: "ɒ", supported: labels,
      source: .init(symbol: "ɑː", probability: 0.99), take: .init(symbol: "ɑː", probability: 0.99), floor: 0.8)
    #expect(wrongSource.quality == .unassessed && wrongSource.kind == .referenceUncertain)
  }
  @Test func UKContrastsArePreservedAndOnlyDeclaredNeighboursAreAmber() {
    func compare(_ expected: String, _ heard: String) -> PronunciationQuality {
      UKReferenceQuality.decide(expected: expected, supported: labels,
        source: .init(symbol: expected, probability: 0.99), take: .init(symbol: heard, probability: 0.99), floor: 0.8).quality
    }
    #expect(compare("ɒ","ɒ") == .correct)
    #expect(compare("ɒ","ɑː") == .incorrect)
    #expect(compare("ɛ","æ") == .nearCorrect)
    #expect(compare("ɛ","ɪ") == .nearCorrect)
    #expect(compare("æ","ɪ") == .incorrect)
    #expect(compare("ɜː","ɜː") == .unassessed)
  }
}

@Suite struct UKEncoderRuntimeTests {
  struct Fixture: Decodable {
    let frames: Int
    let hiddenIndices: [Int]
    let hidden: [Double]
    let logIndices: [Int]
    let logp: [Double]
  }
  @Test func nativeEncoderMatchesOriginalPytorchOnIdenticalPCM() throws {
    let fixtures = Bundle(for: UKPitchFixtureLocator.self)
    let source = try #require(fixtures.url(forResource: "harmonic-120", withExtension: "wav"))
    let expectedURL = try #require(fixtures.url(forResource: "encoder-pytorch", withExtension: "json"))
    let expected = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: expectedURL))
    let directory = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    let actual = try UKReferenceAdapter.encoderFixture(source, directory: directory)
    #expect(actual.frames == expected.frames)
    #expect(actual.hidden.count == expected.frames*1024 && actual.logp.count == expected.frames*392)
    let hiddenError = zip(expected.hiddenIndices, expected.hidden).map { abs(Double(actual.hidden[$0])-$1) }.max() ?? 0
    let logitsError = zip(expected.logIndices, expected.logp).map { abs(Double(actual.logp[$0])-$1) }.max() ?? 0
    #expect(hiddenError < 0.005)
    #expect(logitsError < 0.005)
    print("UK_ENCODER_PARITY hidden=\(hiddenError), logp=\(logitsError), frames=\(actual.frames)")
  }
}

/// Counts how often the real hasher runs behind a `ModelChecksumCache`.
private final class HashCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func bump() { lock.lock(); count += 1; lock.unlock() }
}

@Suite struct ModelChecksumCacheTests {
  private func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelChecksumCache-\(UUID().uuidString).bin")
    try Data(contents.utf8).write(to: url, options: .atomic)
    return url
  }
  private func rewrite(_ url: URL, _ contents: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(contents.utf8))
    try handle.truncate(atOffset: UInt64(contents.utf8.count))
  }

  /// The reason this type exists: `model.safetensors` is 2,3 GB and `encoder.onnx` 1,26 GB, and both
  /// were hashed again on every assessment job.
  @Test func aModelFileIsHashedOnceUntilItChanges() throws {
    let url = try temporaryFile("original bytes")
    defer { try? FileManager.default.removeItem(at: url) }
    let counter = HashCounter()
    let cache = ModelChecksumCache { url in counter.bump(); return try BuddyModelPackage.checksum(url) }
    let first = try cache.hash(url)
    #expect(first == (try BuddyModelPackage.checksum(url)))
    #expect(try cache.hash(url) == first)
    #expect(counter.value == 1) // the second validate never reads the file
    // One appended byte is a new size and a new modification time.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("!".utf8)); try handle.close()
    let second = try cache.hash(url)
    #expect(counter.value == 2)
    #expect(second != first)
    #expect(second == (try BuddyModelPackage.checksum(url)))
  }

  /// Same length, different bytes: size alone would miss it, the modification time does not.
  @Test func aFileRewrittenToTheSameLengthIsHashedAgain() throws {
    let url = try temporaryFile("aaaaaaaa")
    defer { try? FileManager.default.removeItem(at: url) }
    let counter = HashCounter()
    let cache = ModelChecksumCache { url in counter.bump(); return try BuddyModelPackage.checksum(url) }
    let first = try cache.hash(url)
    try rewrite(url, "bbbbbbbb")
    let second = try cache.hash(url)
    #expect(counter.value == 2)
    #expect(second != first)
    #expect(second == (try BuddyModelPackage.checksum(url)))
  }
}

@Suite struct UKPackageRuntimeTests {
  @Test func installDetectsTamperingAndCanRepairWithoutChangingBundledModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UKPackageTest-\(UUID())")
      .appendingPathComponent(String(repeating: "long-container-path-", count: 6))
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BackendPaths(root: root)
    try paths.prepare()
    let bundled = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    let original = try BuddyModelPackage.checksum(bundled.appendingPathComponent("uk-vowels.json"))
    let package = UKReferencePackage(paths: paths, bundled: bundled)
    try await package.install()
    // W7: the first validate hashes every file in `checksums.json` — `encoder.onnx` alone is 1,26 GB
    // — and the second answers from `ModelChecksumCache` after one `stat` per file. This ran twice
    // per PhoneticXeus job. Relative, not absolute: a loaded machine slows both.
    let coldMark = ContinuousClock.now
    let installed = try await package.validate()
    let cold = coldMark.duration(to: .now)
    let warmMark = ContinuousClock.now
    #expect(try await package.validate() == installed)
    let warm = warmMark.duration(to: .now)
    print("UK_VALIDATE cold=\(cold) warm=\(warm)")
    #expect(warm < cold/4)
    // …and a changed file is still caught: the cache is keyed by size, modification time and inode.
    try Data("tampered".utf8).write(to: installed.appendingPathComponent("uk-vowels.json"), options: .atomic)
    do {
      _ = try await package.validate()
      Issue.record("Tampered model must never be accepted")
    } catch BuddyError.checksum { } catch { Issue.record("Wrong validation error: \(error)") }
    try await package.install()
    let repaired = try await package.validate()
    #expect(try BuddyModelPackage.checksum(repaired.appendingPathComponent("uk-vowels.json")) == original)
    #expect(try BuddyModelPackage.checksum(bundled.appendingPathComponent("uk-vowels.json")) == original)
    // Run from the sandboxed test host, including words absent from the dictionary.
    for _ in 0..<8 {
      let generator = UKG2P(package: package)
      let generated = try await generator.pronunciation("shadowing")
      #expect(generated.ipa == "ʃˈædəʊɪŋ")
      #expect(generated.source == "eSpeak NG en-gb generated IPA")
    }
    let american = try await UKG2P(package: package).pronunciation("shadowing", accent: .us)
    #expect(american.ipa == "ʃˈædoʊɪŋ")
    #expect(american.source == "eSpeak NG en-us generated IPA")
    try await package.remove()
    #expect(await !package.installed())
  }
}

@Suite struct UKDictionaryCompatibilityTests {
  @Test func centralVowelInPronunciationUsesTheEncodersExistingToken() throws {
    let units = try #require(UKPhoneInventory.parse("pɹənˌɐnsɪˈeɪʃən"))
    let central = try #require(units.first { $0.symbol == "ɐ" })
    #expect(central.isNucleus && central.stress == 2)
    let url = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference/vocab.json")
    let vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
    #expect(UKPhoneInventory.ctcTokens("ɐ", vocabulary: vocabulary) == [20])
    #expect(UKPhoneInventory.ctcTokens("ɐ", vocabulary: vocabulary)
      != UKPhoneInventory.ctcTokens("ʌ", vocabulary: vocabulary))
    try UKReferenceAdapter.validateTargets([.init(id: "pronunciation", text: "pronunciation,",
      variants: ["pɹənˌɐnsɪˈeɪʃən"], dictionarySources: ["britfone"], sourceStart: 4.72, sourceEnd: 5.57)], vocabulary: vocabulary)
    let decision = UKReferenceQuality.decide(expected: "ɐ", supported: ["ʌ"],
      source: .init(symbol: "ʌ", probability: 1), take: .init(symbol: "ʌ", probability: 1), floor: 0.8)
    #expect(decision.quality == .unassessed) // Encoder support is not a new grading head.
  }

  @Test func unsupportedTargetNamesItsWord() throws {
    let word = PronunciationWordTarget(id: "x", text: "broken", variants: ["☃"],
      dictionarySources: [], sourceStart: 0, sourceEnd: 1)
    do {
      try UKReferenceAdapter.validateTargets([word], vocabulary: ["b": 1])
      Issue.record("Expected an unsupported target error")
    } catch let error as UKReferenceError {
      #expect(error.word == "broken")
      #expect(error.localizedDescription == "assessment.uk.error.word_phones")
    }
    #expect(UKReferenceError.wordAlignment("short").localizedDescription != UKReferenceError.wordPhones("short").localizedDescription)
  }

  @Test func inlineFailureShowsStoredReasonAndOldJobsRemainReadable() throws {
    let (_, fixture) = try AssessedReviewFixtures.make()
    var failed = fixture
    failed.status = .failed
    failed.error = "assessment.uk.error.phones"
    #expect(failed.inlineMessageKey == "assessment.uk.error.phones")
    failed.errorWord = "pronunciation"
    let data = try JSONEncoder().encode(failed)
    #expect(try JSONDecoder().decode(PronunciationJob.self, from: data).errorWord == "pronunciation")
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "errorWord")
    let old = try JSONDecoder().decode(PronunciationJob.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.errorWord == nil)
    #expect(old.inlineMessageKey == "assessment.uk.error.phones")
  }
}
