import Foundation
import Testing
@testable import ToSpeech

@Suite("Capture tick decision")
struct CaptureTickTests {
  private func policy(max: Double, fixed: Bool, silence: Double = 1.5) -> ProductionCapturePolicy {
    try! ProductionCapturePolicy(
      countdown: 0, trailingSilence: silence, maximumDuration: max, fixedWindow: fixed)
  }
  private let loud: Float = -10   // above the -42 dB speech threshold
  private let quiet: Float = -120  // silence

  // MARK: Fixed window — records the full source-sentence duration, never ends early.

  @Test func fixedWindowKeepsWaitingBeforeAnyVoice() {
    let d = CaptureTick.decide(
      phase: .awaitingSpeech, elapsed: 0.5, remaining: 0, delta: 0.1, levelDB: quiet,
      policy: policy(max: 3, fixed: true))
    #expect(d == .advance(phase: .awaitingSpeech, remaining: 2.5))
  }

  @Test func fixedWindowEntersRecordingOnVoice() {
    let d = CaptureTick.decide(
      phase: .awaitingSpeech, elapsed: 0.5, remaining: 0, delta: 0.1, levelDB: loud,
      policy: policy(max: 3, fixed: true))
    #expect(d == .advance(phase: .recording, remaining: 2.5))
  }

  @Test func fixedWindowDoesNotFinishEarlyOnSilence() {
    // Was recording, now silent, still well within the window: must NOT go to trailingSilence
    // and must NOT finish — it keeps recording the whole source duration.
    let d = CaptureTick.decide(
      phase: .recording, elapsed: 1.0, remaining: 0.4, delta: 0.1, levelDB: quiet,
      policy: policy(max: 3, fixed: true))
    #expect(d == .advance(phase: .recording, remaining: 2.0))
  }

  @Test func fixedWindowFinishesExactlyAtSourceDuration() {
    let d = CaptureTick.decide(
      phase: .recording, elapsed: 3.0, remaining: 1.0, delta: 0.1, levelDB: loud,
      policy: policy(max: 3, fixed: true))
    #expect(d == .finish(reachedLimit: true))
  }

  // MARK: Normal mode unchanged (regression guard).

  @Test func normalStartsRecordingOnVoice() {
    let d = CaptureTick.decide(
      phase: .awaitingSpeech, elapsed: 0.5, remaining: 0, delta: 0.1, levelDB: loud,
      policy: policy(max: 10, fixed: false, silence: 1.5))
    #expect(d == .advance(phase: .recording, remaining: 1.5))
  }

  @Test func normalMovesToTrailingSilenceWhenVoiceStops() {
    let d = CaptureTick.decide(
      phase: .recording, elapsed: 2.0, remaining: 1.5, delta: 0.1, levelDB: quiet,
      policy: policy(max: 10, fixed: false, silence: 1.5))
    #expect(d == .advance(phase: .trailingSilence, remaining: 1.5))
  }

  @Test func normalFinishesAfterTrailingSilenceElapses() {
    let d = CaptureTick.decide(
      phase: .trailingSilence, elapsed: 4.0, remaining: 0.05, delta: 0.1, levelDB: quiet,
      policy: policy(max: 10, fixed: false, silence: 1.5))
    #expect(d == .finish(reachedLimit: false))
  }

  @Test func normalHitsHardMaximum() {
    let d = CaptureTick.decide(
      phase: .recording, elapsed: 10.0, remaining: 1.5, delta: 0.1, levelDB: loud,
      policy: policy(max: 10, fixed: false, silence: 1.5))
    #expect(d == .finish(reachedLimit: true))
  }
}
