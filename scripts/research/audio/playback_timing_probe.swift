import AVFAudio
import Foundation

enum ProductionPracticeError: Error { case sourceUnavailable, invalidPlaybackRange }
// Standalone device probe, compiled with the actual ProductionAudioPlayer source.
// Plays silence only. Timing bounds include startup/output latency on the test Mac.
@main struct PlaybackProbe {
  @MainActor static func main() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tospeech-playback-probe-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
      buffer.frameLength = 48_000
      buffer.floatChannelData![0].initialize(repeating: 0, count: 48_000)
      try file.write(from: buffer)
    }
    let player = ProductionAudioPlayer()
    for rate in [0.5, 0.75, 1.0] {
      var completed = false
      var finishSeconds = 0.0
      let started = Date()
      try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: rate) {
        finishSeconds = Date().timeIntervalSince(started)
        completed = true
      }
      try await Task.sleep(for: .milliseconds(500))
      let sourceAtHalfSecond = player.sourceSeconds
      while !completed && Date().timeIntervalSince(started) < 5 {
        try await Task.sleep(for: .milliseconds(20))
      }
      guard completed, finishSeconds >= 1 / rate - 0.12, finishSeconds < 1 / rate + 0.6,
        abs(sourceAtHalfSecond - 0.5 * rate) < 0.2,
        player.sourceFrame == 48_000 else { fatalError("bad playback timing: rate=\(rate) duration=\(finishSeconds) sourceAtHalfSecond=\(sourceAtHalfSecond)") }
      print("PASS rate=\(rate) completion=\(finishSeconds)s sourceAtHalfSecond=\(sourceAtHalfSecond)s")
    }
    var callbacks = 0
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 0.5) { callbacks += 1 }
    try await Task.sleep(for: .milliseconds(200))
    player.pause()
    let pausedFrame = player.sourceFrame
    try await Task.sleep(for: .milliseconds(200))
    guard player.sourceFrame == pausedFrame, callbacks == 0 else { fatalError("pause advanced playback") }
    try player.seek(to: 24_000)
    guard player.sourceFrame == 24_000, player.state == .paused else { fatalError("paused seek failed") }
    let resumed = Date()
    try player.resume()
    while callbacks == 0 && Date().timeIntervalSince(resumed) < 3 { try await Task.sleep(for: .milliseconds(20)) }
    guard callbacks == 1, Date().timeIntervalSince(resumed) >= 0.88 else { fatalError("resume completed early or callback missing") }
    print("PASS pause/seek/resume: one completion after remaining slowed span")
    try player.play(url: url, startFrame: 0, endFrame: 48_000, speed: 0.5) { callbacks += 1 }
    try await Task.sleep(for: .milliseconds(100))
    player.stop()
    try await Task.sleep(for: .milliseconds(2200))
    guard callbacks == 1, player.state == .idle else { fatalError("cancelled playback completed") }
    print("PASS stop: no stale completion")
  }
}
