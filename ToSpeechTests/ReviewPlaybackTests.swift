import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@Suite struct ReviewWordPlaybackTests {
  private func fixture() -> (LessonSentence, PronunciationEvidence) {
    let word = LessonWord(id: "late", text: "hello", ipaUK: "həˈləʊ", ipaUS: nil, span: .init(start: 10.2, end: 10.5))
    let sentence = LessonSentence(id: "s", number: 1, text: "hello", translation: "", span: .init(start: 10, end: 11), words: [word])
    let evidence = PronunciationEvidence(words: [.init(target: .init(id: word.id, text: word.text, variants: [], dictionarySources: [], sourceStart: 10.2, sourceEnd: 10.5), referenceIPA: word.ipaUK, phones: [
      .init(id: 0, kind: .uncertain, expected: "h", observed: nil, start: 0.8, end: 1.1),
      .init(id: 1, kind: .scored, expected: "ə", observed: nil, start: 1.2, end: 1.4)
    ], supported: true)], duration: 2, recognizedPhones: [])
    return (sentence, evidence)
  }

  @Test func sourceAndRecordingUseIndependentWordClocksAndStopAtBoundaries() {
    let (sentence, evidence) = fixture()
    #expect(ReviewWordPlayback.wordID(at: 10.3, clock: .source, sentence: sentence, evidence: evidence) == "late")
    #expect(ReviewWordPlayback.wordID(at: 0.9, clock: .recording, sentence: sentence, evidence: evidence) == "late")
    #expect(ReviewWordPlayback.wordID(at: 0.3, clock: .recording, sentence: sentence, evidence: evidence) == nil)
    #expect(ReviewWordPlayback.wordID(at: 10.3, clock: .recording, sentence: sentence, evidence: evidence) == nil)
    #expect(ReviewWordPlayback.wordID(at: 1.4, clock: .recording, sentence: sentence, evidence: evidence) == nil)
    #expect(ReviewWordPlayback.wordID(at: 10.5, clock: .source, sentence: sentence, evidence: evidence) == nil)
    #expect(ReviewWordPlayback.wordID(at: .nan, clock: .source, sentence: sentence, evidence: evidence) == nil)
  }

  @Test func missingRecordingEvidenceNeverFallsBackToSourceOrEstimatedDuration() {
    let (sentence, _) = fixture()
    #expect(ReviewWordPlayback.wordID(at: 10.3, clock: .source, sentence: sentence, evidence: nil) == "late")
    #expect(ReviewWordPlayback.wordID(at: 10.3, clock: .recording, sentence: sentence, evidence: nil) == nil)
    #expect(ReviewWordPlayback.wordID(at: 0.3, clock: .recording, sentence: sentence, evidence: nil) == nil)
  }
}

@MainActor @Suite(.serialized) struct SimultaneousPlaybackTests {
  private func silence(rate: Double, seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("duet-\(UUID()).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let count = UInt32((rate * seconds).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
    buffer.frameLength = count
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(count))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }
  private func until(_ predicate: () -> Bool) async throws {
    for _ in 0..<250 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(predicate(), "Playback did not reach the expected state within five seconds")
  }

  @Test func startsTogetherAndKeepsLongerTakePlayingAfterSourceEnds() async throws {
    let a = try silence(rate: 48_000, seconds: 1), b = try silence(rate: 44_100, seconds: 1.4)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let player = ProductionAudioPlayer()
    defer { player.stop() }
    var completions = 0
    try player.playTogether(sourceURL: a, sourceFrames: 9_600..<33_600, takeURL: b, takeFrames: 0..<61_740) { completions += 1 }
    #expect(player.isSimultaneous && !player.canSeek && player.speed == 1)
    #expect(abs(player.rangeDuration - 0.5) < 0.001)
    #expect(abs(player.secondDuration - 1.4) < 0.001)
    try await until { player.rangeElapsed > 0.16 && player.secondElapsed > 0.16 }
    #expect(abs(player.rangeElapsed - player.secondElapsed) < 0.06)
    try await until { player.rangeElapsed >= 0.5 }
    #expect(player.state == .playing && completions == 0)
    player.pause()
    let frozen = player.secondElapsed
    try await Task.sleep(for: .milliseconds(120))
    #expect(player.state == .paused && player.secondElapsed == frozen)
    try player.resume()
    try await until { completions == 1 }
    #expect(player.state == .idle)
    #expect(abs(player.secondElapsed - 1.4) < 0.001)
    #expect(player.sourceFrame == 33_600)
  }

  @Test func shorterTakeCannotStopSourceAndReplacingPlaybackCancelsBothCompletions() async throws {
    let a = try silence(rate: 48_000, seconds: 1.3), b = try silence(rate: 16_000, seconds: 0.35)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let player = ProductionAudioPlayer()
    defer { player.stop() }
    var oldCompletions = 0, replacementCompletions = 0
    try player.playTogether(sourceURL: a, sourceFrames: 0..<62_400, takeURL: b, takeFrames: 0..<5_600) { oldCompletions += 1 }
    try await until { player.secondElapsed >= 0.35 }
    #expect(player.state == .playing && oldCompletions == 0)
    try player.play(url: b, startFrame: 0, endFrame: 5_600, speed: 1) { replacementCompletions += 1 }
    #expect(!player.isSimultaneous && player.assetURL == b)
    try await until { replacementCompletions == 1 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(oldCompletions == 0)
    player.stop()
    #expect(player.assetURL == nil)
  }

  @Test func invalidSecondFileLeavesNoSourcePlaying() throws {
    let a = try silence(rate: 48_000, seconds: 1)
    defer { try? FileManager.default.removeItem(at: a) }
    let player = ProductionAudioPlayer()
    #expect(throws: ProductionPracticeError.invalidPlaybackRange) {
      try player.playTogether(sourceURL: a, sourceFrames: 0..<48_000, takeURL: a, takeFrames: 0..<48_001)
    }
    #expect(player.state == .idle && !player.isSimultaneous && player.assetURL == nil)
  }
}
