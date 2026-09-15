import AVFAudio
import Foundation
import Testing
@testable import ToSpeech

struct RubberBandPlaybackTests {
  private func signal() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("r3-test-\(UUID()).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for frame in 0..<48_000 {
      // Voicing through the last frame catches lost final output; identical
      // stereo channels also check that the renderer preserves channel layout.
      let value = Float(sin(2 * Double.pi * 220 * Double(frame) / 48_000)) * 0.2
      buffer.floatChannelData![0][frame] = value
      buffer.floatChannelData![1][frame] = value
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  @Test(arguments: [0.5, 0.75])
  func r3PreservesPitchStereoAndTailWhileStretchingSelectedSpan(speed: Double) async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let audio = try await RubberBandRenderer.render(url: input, startFrame: 4_800, endFrame: 43_200, speed: speed)
    let file = try AVAudioFile(forReading: audio.url)
    #expect(file.length == Int64((38_400 / speed).rounded()))
    #expect(file.processingFormat.channelCount == 2)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
    try file.read(into: buffer)
    #expect(Int64(buffer.frameLength) == file.length)
    let channels = try #require(buffer.floatChannelData)
    let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    #expect(samples.allSatisfy { $0.isFinite && abs($0) < 1 })
    let tail = samples.suffix(2_400)
    #expect(tail.map { $0 * $0 }.reduce(0, +) / Float(tail.count) > 0.005)
    let middle = Array(samples.dropFirst(4_800).dropLast(4_800))
    let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    let frequency = Double(crossings) * 48_000 / Double(middle.count)
    #expect(abs(frequency - 220) < 3)
    let right = Array(UnsafeBufferPointer(start: channels[1], count: samples.count))
    #expect(zip(samples, right).allSatisfy { abs($0 - $1) < 0.0001 })
  }

  @Test func r3RejectsInvalidSpanWithoutTouchingInput() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let original = try Data(contentsOf: input)
    await #expect(throws: RubberBandRenderError.self) {
      try await RubberBandRenderer.render(url: input, startFrame: 0, endFrame: 48_001, speed: 0.5)
    }
    #expect(try Data(contentsOf: input) == original)
  }

  @MainActor @Test func preparationCanPauseAndStopWithoutCompletingOrReportingCancelledWork() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let gate = RenderGate()
    let player = ProductionAudioPlayer(renderSlowAudio: { _, _, _, _ in try await gate.wait() })
    var completed = 0, errors = 0
    player.onFailure = { _ in errors += 1 }
    try player.play(url: input, startFrame: 4_800, endFrame: 43_200, speed: 0.5) { completed += 1 }
    while !(await gate.isWaiting) { await Task.yield() }
    #expect(player.state == .preparing)
    #expect(!player.canSeek)
    player.pause()
    #expect(player.state == .paused)
    #expect(player.sourceFrame == 4_800)
    try player.resume()
    #expect(player.state == .preparing)
    player.stop()
    await gate.fail() // Late non-cancellation failure from obsolete generation.
    for _ in 0..<10 { await Task.yield() }
    #expect(player.state == .idle)
    #expect(!player.isPreparing)
    #expect(completed == 0)
    #expect(errors == 0)
  }

  @MainActor @Test func missingHelperFallsBackToTimePitchInsteadOfFailing() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let player = ProductionAudioPlayer(renderSlowAudio: { _, _, _, _ in throw RubberBandRenderError.unavailable })
    var failure: String?
    player.onFailure = { failure = $0 }
    try player.play(url: input, startFrame: 4_800, endFrame: 43_200, speed: 0.5)
    while player.isPreparing { try await Task.sleep(for: .milliseconds(5)) }
    #expect(failure == nil)
    #expect(player.state == .playing)
    #expect(player.speed == 0.5)
    player.stop()
  }

  @Test func helperIsBundledNextToTheApp() {
    #expect(RubberBandRenderer.isAvailable())
  }

  @MainActor @Test func preparationFailureIsVisibleAndCannotCompleteSourceListen() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let player = ProductionAudioPlayer(renderSlowAudio: { _, _, _, _ in throw RubberBandRenderError.incomplete })
    var completed = false
    var failure: String?
    player.onFailure = { failure = $0 }
    try player.play(url: input, startFrame: 0, endFrame: 48_000, speed: 0.75) { completed = true }
    for _ in 0..<100 where failure == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(failure == "playback.r3.incomplete")
    #expect(player.state == .failed("playback.r3.incomplete"))
    #expect(!completed)
  }

  @MainActor @Test func changingSpeedKeepsThePausedSourceFrame() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let player = ProductionAudioPlayer()
    try player.play(url: input, startFrame: 4_800, endFrame: 43_200, speed: 1)
    try await Task.sleep(for: .milliseconds(90))
    player.pause()
    let pausedFrame = player.sourceFrame
    #expect(pausedFrame > 4_800)

    try player.updateSpeed(0.75)
    #expect(player.sourceFrame == pausedFrame)
    while player.isPreparing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(player.state == .paused)
    #expect(player.sourceFrame == pausedFrame)
    #expect(player.speed == 0.75)

    try player.updateSpeed(1.25)
    #expect(player.state == .paused)
    #expect(player.sourceFrame == pausedFrame)
    #expect(player.speed == 1.25)
  }

  @MainActor @Test func resumingWhileNewSpeedPreparesHonorsTheLatestPlayIntent() async throws {
    let input = try signal()
    defer { try? FileManager.default.removeItem(at: input) }
    let prepared = try await RubberBandRenderer.render(
      url: input, startFrame: 4_800, endFrame: 43_200, speed: 0.5)
    let gate = RenderGate()
    let player = ProductionAudioPlayer(renderSlowAudio: { _, _, _, _ in try await gate.wait() })
    try player.play(url: input, startFrame: 4_800, endFrame: 43_200, speed: 1)
    try await Task.sleep(for: .milliseconds(60))
    player.pause()
    let pausedFrame = player.sourceFrame
    try player.updateSpeed(0.5)
    while !(await gate.isWaiting) { await Task.yield() }
    try player.resume()
    #expect(player.state == .preparing)
    await gate.succeed(prepared)
    while player.isPreparing { try await Task.sleep(for: .milliseconds(5)) }
    #expect(player.state == .playing)
    #expect(player.sourceFrame >= pausedFrame)
    player.stop()
  }
}

private actor RenderGate {
  var continuation: CheckedContinuation<RubberBandRender, Error>?
  var isWaiting: Bool { continuation != nil }
  func wait() async throws -> RubberBandRender {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func succeed(_ render: RubberBandRender) {
    continuation?.resume(returning: render)
    continuation = nil
  }
  func fail() { continuation?.resume(throwing: RubberBandRenderError.incomplete); continuation = nil }
}
