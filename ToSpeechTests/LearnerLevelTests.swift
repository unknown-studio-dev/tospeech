import Foundation
import Testing
@testable import ToSpeech

@Suite("Learner level presets")
struct LearnerLevelTests {
  @Test func beginnersGetSlowLoopingUntimedDefaults() {
    var preferences = Preferences()
    preferences.speed = 1.5; preferences.repeats = 1; preferences.autoRecord = true
    LearnerLevel.beginning.apply(to: &preferences)
    #expect(preferences.speed == 0.75)
    #expect(preferences.repeats == 5)
    #expect(preferences.countdown == 3)
    #expect(preferences.showTranslation)
    #expect(!preferences.autoRecord)
    #expect(preferences.dictationTimeLimit == nil)
  }

  @Test func confidentSpeakersGetNaturalSpeedNoTranslationAndAutoRecord() {
    var preferences = Preferences()
    LearnerLevel.confidentConversation.apply(to: &preferences)
    #expect(preferences.speed == 1)
    #expect(preferences.repeats == 1)
    #expect(preferences.countdown == 1.5)
    #expect(!preferences.showTranslation)
    #expect(preferences.autoRecord)
    #expect(preferences.dictationTimeLimit == 15)
  }

  @Test func presetsOnlyUseValuesTheControlsOffer() {
    for level in LearnerLevel.allCases {
      #expect(PracticeOptions.speeds.contains(level.speed))
      #expect(PracticeOptions.repeatCounts.contains(level.repeats))
      #expect(PracticeOptions.countdowns.contains(level.countdown))
      if let limit = level.dictationTimeLimit { #expect(DictationProgress.timeLimits.contains(limit)) }
    }
  }

  @Test func matchingRecognisesAnAppliedPresetAndNothingElse() {
    var preferences = Preferences()
    LearnerLevel.basicConversation.apply(to: &preferences)
    #expect(LearnerLevel.matching(preferences) == .basicConversation)
    preferences.repeats = 10
    #expect(LearnerLevel.matching(preferences) == nil)
    // Unrelated preferences do not break the match.
    LearnerLevel.beginning.apply(to: &preferences)
    preferences.showIPA = false; preferences.video = true
    #expect(LearnerLevel.matching(preferences) == .beginning)
  }
}
