import Foundation

protocol DictationStorage: Sendable {
  func dictationProgress(lessonID: UUID) async throws -> [DictationProgress]
  func saveDictationProgress(_ value: DictationProgress) async throws
}

extension ProductionDatabase: DictationStorage {}

@MainActor protocol DictationAudioPlaying: AnyObject {
  var onFailure: (@MainActor @Sendable (String) -> Void)? { get set }
  var state: ProductionAudioPlayer.State { get }
  var rangeProgress: Double { get }
  func playSentence(_ target: ProductionPracticeTarget, speed: Double,
    completion: @escaping @MainActor @Sendable () -> Void) throws
  func stop()
}

extension ProductionAudioPlayer: DictationAudioPlaying {
  func playSentence(_ target: ProductionPracticeTarget, speed: Double,
    completion: @escaping @MainActor @Sendable () -> Void) throws {
    try play(url: target.audioURL, startFrame: target.startFrame,
      endFrame: target.playbackEndFrame, speed: speed, onCompletion: completion)
  }
}
