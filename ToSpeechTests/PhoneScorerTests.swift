import Foundation
import AVFAudio
import Testing
@testable import ToSpeech

@Suite struct PhoneScorerTests {
  @Test func audioReaderPreservesTailAcrossDecoderAndConverterBlocks() throws {
    for rate in [16000.0, 44100.0, 48000.0] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("tail.caf")
      let count = AVAudioFrameCount(rate*1.0661875)
      let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
      buffer.frameLength = count
      for i in 0..<Int(count) {
        buffer.floatChannelData![0][i] = i > Int(count)-Int(rate*0.025) ? 0.35 : 0.05
      }
      do { let writer = try AVAudioFile(forWriting: url, settings: format.settings); try writer.write(from: buffer) }
      let file = try AVAudioFile(forReading: url)
      let decoded = try CoreMLWordAligner.samples(file: file, start: 0, end: Double(count)/rate)
      #expect(abs(decoded.count-Int((Double(count)*16000/rate).rounded())) <= 2)
      #expect(decoded.suffix(150).allSatisfy { $0 > 0.25 })
      let cropped = try CoreMLWordAligner.samples(file: file, start: 0.05, end: Double(count)/rate)
      #expect(abs(cropped.count-Int(((Double(count)/rate-0.05)*16000).rounded())) <= 2)
    }
  }
  @Test func rhoticFoldsStayWithinEachWordAndRetainDisplayPhones() {
    #expect(PhoneScorerMath.units(["ɑ", "ɹ", "m"]).map(\.symbol) == ["aar", "m"])
    #expect(PhoneScorerMath.units(["ɛ", "r"]).first?.displayPhones == ["ɛ", "r"])
    #expect(PhoneScorerMath.units(["ɑ"]).map(\.symbol) == ["ɑ"])
    #expect(PhoneScorerMath.units(["ɹ"]).map(\.symbol) == ["ɹ"])
    #expect(PhoneScorerMath.units(["ə", "ɚ"]).map(\.symbol) == ["ʌ", "ɝ"])
  }
  @Test func scoreBandsAreIndependentOfRecognitionConfidence() {
    #expect(PhoneScorerMath.quality(0) == .incorrect)
    #expect(PhoneScorerMath.quality(24.99) == .incorrect)
    #expect(PhoneScorerMath.quality(25) == .nearCorrect)
    #expect(PhoneScorerMath.quality(74.99) == .nearCorrect)
    #expect(PhoneScorerMath.quality(75) == .correct)
    #expect(PhoneScorerMath.quality(100) == .correct)
    for value in [Double.nan, .infinity, -1, 101] { #expect(PhoneScorerMath.quality(value) == .unassessed) }
  }
  @Test func ordinalScoreDoesNotInventAnObservedPhone() throws {
    let phone = PhoneDifference(id: 0, kind: .scored, expected: "ə", observed: nil, start: 0, end: 0.2,
      quality: .nearCorrect, score: 50, sourceScore: 90)
    let decoded = try JSONDecoder().decode(PhoneDifference.self, from: JSONEncoder().encode(phone))
    #expect(decoded == phone && decoded.observed == nil)
    #expect(PronunciationDisplay.quality(decoded, supported: true) == .nearCorrect)
    let unscored = PhoneDifference(id: 0, kind: .scored, expected: "ə", observed: nil, start: nil, end: nil)
    #expect(PronunciationDisplay.quality(unscored, supported: true) == .unassessed)
  }
  @Test func sourceGateRetainsRawScoreWithoutColoringItCorrect() {
    let phone = PhoneDifference(id: 0, kind: .referenceUncertain, expected: "v", observed: nil, start: 0, end: 0.2,
      quality: .correct, score: 95, sourceScore: 18)
    #expect(PronunciationDisplay.quality(phone, supported: true) == .unassessed)
    #expect(phone.score == 95)
  }
  @Test func featurePoolingUsesPopulationDeviationAndBlankCompetitor() throws {
    // Two frames with symmetric posterior mass. Blank is a real competitor.
    let logits: [Float] = Array(repeating: 0, count: 90)
    let rows = try PhoneScorerMath.logProbabilities(logits, width: 45)
    let hidden = Array(repeating: Float(1), count: 384) + Array(repeating: Float(3), count: 384)
    let features = try PhoneScorerMath.pool(hidden: hidden, logProbabilities: rows, spans: [.init(start: 0, end: 2)], ids: [0])
    #expect(features.count == 772)
    #expect(features[0..<384].allSatisfy { abs($0-2) < 0.00001 })
    #expect(features[384..<768].allSatisfy { abs($0-1) < 0.00001 })
    #expect(abs(features[768]-1/45) < 0.00001)
    #expect(abs(features[769]) < 0.00001)
    #expect(abs(features[770]-1) < 0.00001)
    #expect(features[771] == 1)
  }
  @Test func invalidSpanOrNonfiniteOutputCannotProduceAGrade() throws {
    let rows = try PhoneScorerMath.logProbabilities(Array(repeating: 0, count: 90), width: 45)
    #expect(throws: (any Error).self) {
      try PhoneScorerMath.pool(hidden: Array(repeating: 0, count: 768), logProbabilities: rows,
        spans: [.init(start: 0, end: 3)], ids: [0])
    }
    #expect(throws: (any Error).self) { try PhoneScorerMath.logProbabilities([.nan, 1], width: 2) }
  }
  @Test func britishAccentFailsBeforeLoadingOrScoring() async throws {
    let paths = BackendPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let scorer = PhoneScorerAdapter(package: PhoneScorerPackage(paths: paths, bundled: nil))
    do {
      _ = try await scorer.assess(sourceURL: paths.root, sourceSpan: .init(start: 0, end: 1), takeURL: paths.root, words: [], accent: .uk)
      Issue.record("US scorer accepted a British reference")
    } catch PhoneScorerError.unsupportedAccent {} catch { Issue.record("Unexpected error: \(error)") }
  }
}
