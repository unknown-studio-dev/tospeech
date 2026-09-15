import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

@MainActor
struct UKPhonemeAudioPlayerTests {
  @Test func everyUKSoundHasOneUniqueBundledClip() throws {
    let resources = UKSoundLibrary.all.compactMap { UKSoundLibrary.audioResource(for: $0.symbol) }
    #expect(resources.count == 44)
    #expect(Set(resources).count == 44)

    let testFile = URL(fileURLWithPath: #filePath)
    let directory = testFile.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("ToSpeech/Resources/UKPhonemes")
    for resource in resources {
      let url = directory.appendingPathComponent(resource).appendingPathExtension("wav")
      let data = try Data(contentsOf: url)
      #expect(data.count > 1_000, "Missing or empty clip: \(resource)")
      #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
      let audio = try AVAudioFile(forReading: url)
      #expect(audio.processingFormat.channelCount == 1, "Clip must be mono: \(resource)")
      #expect(audio.processingFormat.sampleRate == 44_100, "Unexpected sample rate: \(resource)")
      let duration = Double(audio.length) / audio.processingFormat.sampleRate
      #expect((0.12...0.90).contains(duration), "Implausible sound duration: \(resource)")
    }
  }

  @Test func replacesCurrentClipAndIgnoresItsStaleCompletion() {
    let driver = FakePhonemeAudioDriver()
    let player = UKPhonemeAudioPlayer(driver: driver) { URL(fileURLWithPath: "/tmp/\($0).wav") }
    player.play("eɪ")
    let oldCompletion = driver.completion
    player.play("aɪ")
    #expect(driver.playedURLs.map(\.lastPathComponent) == ["UKPhoneme_13.wav", "UKPhoneme_14.wav"])
    #expect(player.playingSymbol == "aɪ")
    oldCompletion?()
    #expect(player.playingSymbol == "aɪ")
    driver.completion?()
    #expect(player.playingSymbol == nil)
  }

  @Test func missingClipFailsVisiblyWithoutFallbackPlayback() {
    let driver = FakePhonemeAudioDriver()
    let player = UKPhonemeAudioPlayer(driver: driver) { _ in nil }
    player.play("p")
    #expect(player.errorKey == "coach.sound.missing")
    #expect(driver.playedURLs.isEmpty)
    #expect(player.playingSymbol == nil)
  }

  @Test func selectionOnlyStopsAClipWhenTheSoundChanges() {
    let driver = FakePhonemeAudioDriver()
    let player = UKPhonemeAudioPlayer(driver: driver) { URL(fileURLWithPath: "/tmp/\($0).wav") }
    player.play("əʊ")
    player.stopIfPlayingDifferentSound(from: "əʊ")
    #expect(player.playingSymbol == "əʊ")
    player.stopIfPlayingDifferentSound(from: "aʊ")
    #expect(player.playingSymbol == nil)
  }
}

@MainActor
private final class FakePhonemeAudioDriver: PhonemeAudioDriving {
  var playedURLs: [URL] = []
  var completion: (@MainActor () -> Void)?

  func play(_ url: URL, completion: @escaping @MainActor () -> Void) throws {
    playedURLs.append(url)
    self.completion = completion
  }

  func stop() { completion = nil }
}
