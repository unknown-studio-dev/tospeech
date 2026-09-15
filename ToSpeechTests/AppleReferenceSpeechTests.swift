import Foundation
import Testing
@testable import ToSpeech

@MainActor
struct AppleReferenceSpeechTests {
  @Test func selectsExactAccentAndBestNonNoveltyVoice() {
    let voices = [
      ReferenceSpeechVoice(id: "australian", language: "en-AU", quality: 3),
      ReferenceSpeechVoice(id: "us", language: "en-US", quality: 3),
      ReferenceSpeechVoice(id: "uk-basic", language: "en-GB", quality: 1),
      ReferenceSpeechVoice(id: "uk-enhanced", language: "en-GB", quality: 2),
      ReferenceSpeechVoice(id: "uk-novelty", language: "en-GB", quality: 3, isNovelty: true)
    ]
    #expect(ReferenceSpeechVoice.preferred(for: .uk, from: voices)?.id == "uk-enhanced")
    #expect(ReferenceSpeechVoice.preferred(for: .us, from: voices)?.id == "us")
    #expect(ReferenceSpeechVoice.preferred(for: .uk, from: [voices[0], voices[1]]) == nil)
  }

  @Test func speaksTextWithoutIPAAndDoesNotQueueAccents() {
    let driver = FakeSpeechDriver()
    let player = AppleReferenceSpeechPlayer(driver: driver)
    player.play("shadowing", accent: .uk)
    #expect(driver.spokenText == "shadowing")
    #expect(driver.voiceID == "uk")
    let oldCompletion = driver.completion
    player.play("we’re", accent: .us)
    #expect(driver.stopCount == 2)
    #expect(driver.voiceID == "us")
    #expect(player.playingAccent == .us)
    oldCompletion?()
    #expect(player.playingAccent == .us)
    driver.completion?()
    #expect(player.playingAccent == nil)
  }

  @Test func usesSystemRecommendedVoiceBeforeAlphabeticalTieBreak() {
    let voices = [
      ReferenceSpeechVoice(id: "eddy", language: "en-US", quality: 1),
      ReferenceSpeechVoice(id: "samantha", language: "en-US", quality: 1, isSystemPreferred: true)
    ]
    #expect(ReferenceSpeechVoice.preferred(for: .us, from: voices)?.id == "samantha")
  }

  @Test func missingVoiceDoesNotFallBackToAnotherAccentAndCanRetry() {
    let driver = FakeSpeechDriver()
    driver.voices.removeAll { $0.language == "en-GB" }
    let player = AppleReferenceSpeechPlayer(driver: driver)
    player.play("hello", accent: .uk)
    #expect(driver.spokenText == nil)
    #expect(player.errorKey == "word.reference.missing.uk")
    #expect(player.playingAccent == nil)
    driver.voices.append(ReferenceSpeechVoice(id: "new-uk", language: "en-GB", quality: 2))
    player.play("hello", accent: .uk)
    #expect(driver.voiceID == "new-uk")
    #expect(player.errorKey == nil)
  }

  @Test func stopClearsPlaybackAndPunctuationDoesNotSpeak() {
    let driver = FakeSpeechDriver()
    let player = AppleReferenceSpeechPlayer(driver: driver)
    player.play("hello", accent: .uk)
    player.stop()
    #expect(player.playingAccent == nil)
    driver.spokenText = nil
    player.play("…!", accent: .uk)
    #expect(driver.spokenText == nil)
    #expect(player.playingAccent == nil)
  }

  @Test func driverFailureIsVisibleAndClearsPlayback() {
    let driver = FakeSpeechDriver()
    driver.shouldFail = true
    let player = AppleReferenceSpeechPlayer(driver: driver)
    player.play("hello", accent: .us)
    #expect(player.errorKey == "word.reference.failed")
    #expect(player.playingAccent == nil)
  }
}

@MainActor
private final class FakeSpeechDriver: ReferenceSpeechDriver {
  var voices = [ReferenceSpeechVoice(id: "uk", language: "en-GB", quality: 1),
                ReferenceSpeechVoice(id: "us", language: "en-US", quality: 1)]
  var spokenText: String?
  var voiceID: String?
  var completion: (@MainActor () -> Void)?
  var stopCount = 0
  var shouldFail = false

  func speak(_ text: String, voiceID: String, completion: @escaping @MainActor () -> Void) throws {
    if shouldFail { throw CocoaError(.featureUnsupported) }
    spokenText = text
    self.voiceID = voiceID
    self.completion = completion
  }

  func stop() { stopCount += 1 }
}
