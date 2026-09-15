import AVFoundation
import Observation

struct ReferenceSpeechVoice: Equatable {
  let id: String
  let language: String
  let quality: Int
  var isNovelty = false
  var isSystemPreferred = false

  static func preferred(for accent: ReferenceAccent, from voices: [Self]) -> Self? {
    let language = accent == .uk ? "en-GB" : "en-US"
    return voices.filter { $0.language == language && !$0.isNovelty }
      .sorted {
        if $0.quality != $1.quality { return $0.quality > $1.quality }
        if $0.isSystemPreferred != $1.isSystemPreferred { return $0.isSystemPreferred }
        return $0.id < $1.id
      }.first
  }
}

@MainActor
protocol ReferenceSpeechDriver: AnyObject {
  var voices: [ReferenceSpeechVoice] { get }
  func speak(_ text: String, voiceID: String, completion: @escaping @MainActor () -> Void) throws
  func stop()
}

/// Uses installed voices only. Never lets AVFoundation choose another accent.
@MainActor
@Observable
final class AppleReferenceSpeechPlayer {
  private(set) var playingAccent: ReferenceAccent?
  private(set) var errorKey: String?
  private let driver: any ReferenceSpeechDriver
  private var requestID: UUID?

  init(driver: (any ReferenceSpeechDriver)? = nil) {
    self.driver = driver ?? AppleReferenceSpeechDriver()
  }

  func play(_ text: String, accent: ReferenceAccent) {
    guard IPAFormatting.isPronounceable(text) else { stop(); errorKey = nil; return }
    start(accent: accent) { voiceID, completion in
      try driver.speak(text, voiceID: voiceID, completion: completion)
    }
  }

  private func start(
    accent: ReferenceAccent,
    speak: (_ voiceID: String, _ completion: @escaping @MainActor () -> Void) throws -> Void
  ) {
    stop()
    errorKey = nil
    guard let voice = ReferenceSpeechVoice.preferred(for: accent, from: driver.voices) else {
      errorKey = accent == .uk ? "word.reference.missing.uk" : "word.reference.missing.us"
      return
    }
    let id = UUID()
    requestID = id
    playingAccent = accent
    do {
      try speak(voice.id) { [weak self] in
        guard let self, self.requestID == id else { return }
        self.playingAccent = nil
        self.requestID = nil
      }
    } catch {
      stop()
      errorKey = "word.reference.failed"
    }
  }

  func stop() {
    requestID = nil
    playingAccent = nil
    driver.stop()
  }
}

@MainActor
private final class AppleReferenceSpeechDriver: NSObject, ReferenceSpeechDriver, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var current: ObjectIdentifier?
  private var completion: (@MainActor () -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  var voices: [ReferenceSpeechVoice] {
    let preferredIDs = Set(["en-GB", "en-US"].compactMap {
      AVSpeechSynthesisVoice(language: $0)?.identifier
    })
    return AVSpeechSynthesisVoice.speechVoices().map {
      ReferenceSpeechVoice(id: $0.identifier, language: $0.language,
        quality: $0.quality.rawValue, isNovelty: $0.voiceTraits.contains(.isNoveltyVoice),
        isSystemPreferred: preferredIDs.contains($0.identifier))
    }
  }

  func speak(_ text: String, voiceID: String, completion: @escaping @MainActor () -> Void) throws {
    try speak(AVSpeechUtterance(string: text), voiceID: voiceID, completion: completion)
  }

  private func speak(
    _ utterance: AVSpeechUtterance, voiceID: String,
    completion: @escaping @MainActor () -> Void
  ) throws {
    guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else {
      throw CocoaError(.featureUnsupported)
    }
    utterance.voice = voice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    current = ObjectIdentifier(utterance)
    self.completion = completion
    synthesizer.speak(utterance)
  }

  func stop() {
    current = nil
    completion = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func finish(_ id: ObjectIdentifier) {
    guard current == id else { return }
    current = nil
    let callback = completion
    completion = nil
    callback?()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in self?.finish(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in self?.finish(id) }
  }
}
