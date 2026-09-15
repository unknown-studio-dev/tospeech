import Foundation
import Testing
@testable import ToSpeech

struct OnboardingTests {
  @Test func legacyPreferencesRequireOnboarding() throws {
    let encoded = try JSONEncoder().encode(Preferences())
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "onboardingCompletion")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)

    #expect(!decoded.hasCompletedOnboarding)
  }

  @Test func onboardingCompletionRoundTrips() throws {
    var preferences = Preferences()
    preferences.hasCompletedOnboarding = true

    let decoded = try JSONDecoder().decode(
      Preferences.self, from: JSONEncoder().encode(preferences))

    #expect(decoded.hasCompletedOnboarding)
  }

  @MainActor @Test func downloadStepsRetryTransientFailuresButNotCancellation() async throws {
    struct Flaky: Error {}
    var calls = 0
    var retries: [Int] = []
    try await OnboardingSetupModel.withRetries(attempts: 3, delay: .milliseconds(1)) {
      calls += 1
      if calls < 3 { throw Flaky() }
    } onRetry: { _, next in retries.append(next) }
    #expect(calls == 3)
    #expect(retries == [2, 3])

    calls = 0
    await #expect(throws: Flaky.self) {
      try await OnboardingSetupModel.withRetries(attempts: 2, delay: .milliseconds(1)) {
        calls += 1
        throw Flaky()
      }
    }
    #expect(calls == 2)

    calls = 0
    await #expect(throws: CancellationError.self) {
      try await OnboardingSetupModel.withRetries(attempts: 3, delay: .milliseconds(1)) {
        calls += 1
        throw CancellationError()
      }
    }
    #expect(calls == 1)
  }

  @MainActor @Test func setupStartsWithEveryRequiredCapabilityLocked() {
    let setup = OnboardingSetupModel(
      parakeetModels: nil, pronunciationModels: nil,
      storageReady: false)

    #expect(setup.items.map(\.id) == [
      "storage", "transcription", "apple-speech", "translation", "assessment",
    ])
    #expect(setup.items.allSatisfy { $0.state == .waiting })
    #expect(!setup.isComplete)

    setup.includesTranslation = false
    #expect(setup.items.map(\.id) == ["storage", "transcription", "apple-speech", "assessment"])
  }
}
