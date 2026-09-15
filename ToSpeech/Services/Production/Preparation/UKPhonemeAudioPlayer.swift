import AVFoundation
import Observation

@MainActor
protocol PhonemeAudioDriving: AnyObject {
  func play(_ url: URL, completion: @escaping @MainActor () -> Void) throws
  func stop()
}

@MainActor
@Observable
final class UKPhonemeAudioPlayer {
  private(set) var playingSymbol: String?
  private(set) var errorKey: String?
  private let driver: any PhonemeAudioDriving
  private let locate: (String) -> URL?
  private var requestID: UUID?

  init(
    driver: (any PhonemeAudioDriving)? = nil,
    locate: @escaping (String) -> URL? = {
      Bundle.main.url(forResource: $0, withExtension: "wav")
    }
  ) {
    self.driver = driver ?? AVPhonemeAudioDriver()
    self.locate = locate
  }

  func play(_ symbol: String) {
    stop()
    errorKey = nil
    guard let resource = UKSoundLibrary.audioResource(for: symbol), let url = locate(resource) else {
      errorKey = "coach.sound.missing"
      return
    }
    let id = UUID()
    requestID = id
    playingSymbol = symbol
    do {
      try driver.play(url) { [weak self] in
        guard let self, self.requestID == id else { return }
        self.requestID = nil
        self.playingSymbol = nil
      }
    } catch {
      stop()
      errorKey = "coach.sound.failed"
    }
  }

  func stop() {
    requestID = nil
    playingSymbol = nil
    driver.stop()
  }

  func stopIfPlayingDifferentSound(from symbol: String) {
    if playingSymbol != symbol { stop() }
  }
}

@MainActor
private final class AVPhonemeAudioDriver: NSObject, PhonemeAudioDriving, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var completion: (@MainActor () -> Void)?

  func play(_ url: URL, completion: @escaping @MainActor () -> Void) throws {
    stop()
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = self
    player.prepareToPlay()
    self.player = player
    self.completion = completion
    guard player.play() else {
      stop()
      throw CocoaError(.fileReadUnknown)
    }
  }

  func stop() {
    player?.stop()
    player = nil
    completion = nil
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let id = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
      self.player = nil
      let callback = self.completion
      self.completion = nil
      callback?()
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    audioPlayerDidFinishPlaying(player, successfully: false)
  }
}
