import Foundation
import Testing
@testable import ToSpeech

@Suite struct PronunciationEvidenceTests {
  private func word(_ text: String, _ variants: [String]) -> PronunciationWordTarget {
    .init(id: text, text: text, variants: variants, dictionarySources: ["test"], sourceStart: nil, sourceEnd: nil)
  }
  private func heard(_ phones: [String], confidence: Double = 0.95) -> [RecognizedPhone] {
    phones.enumerated().map { .init(symbol: $0.element, start: Double($0.offset)*0.1,
      end: Double($0.offset+1)*0.1, posterior: confidence) }
  }
  @Test func independentSubstitutionIsAttributedToTheRightWord() throws {
    let result = try PronunciationComparison.compare(targets: [word("very", ["vɛɹi"]), word("well", ["wɛl"])],
      heard: heard(["w","ɛ","ɹ","i","w","ɛ","l"]), duration: 1)
    #expect(result.changedWords == 1)
    let difference = try #require(result.words[0].differences.first)
    #expect(difference.kind == .substitution)
    #expect(difference.expected == "v" && difference.observed == "w")
    #expect(difference.start == 0)
    #expect(result.words[1].differences.isEmpty)
  }
  @Test func UKAndUSVariantsDoNotCreateFalseErrors() throws {
    for sounds in [["n","ɛ","v","ə"], ["n","ɛ","v","ɝ"]] {
      let result = try PronunciationComparison.compare(targets: [word("never", ["nˈɛvə", "ˈnɛvɝ"])], heard: heard(sounds), duration: 1)
      #expect(result.changedWords == 0)
    }
  }
  @Test func deletionInsertionAndLowEvidenceRemainDistinct() throws {
    let missing = try PronunciationComparison.compare(targets: [word("cat", ["kæt"])], heard: heard(["k","æ"]), duration: 1)
    #expect(missing.words[0].differences.contains { $0.kind == .omission && $0.observed == nil && $0.start == nil })
    let extra = try PronunciationComparison.compare(targets: [word("cat", ["kæt"])], heard: heard(["k","æ","t","ə"]), duration: 1)
    #expect(extra.words[0].differences.contains { $0.kind == .insertion })
    let uncertain = try PronunciationComparison.compare(targets: [word("cat", ["kæt"])], heard: heard(["k","æ","t"], confidence: 0.3), duration: 1)
    #expect(uncertain.words[0].phones.allSatisfy { $0.kind == .uncertain })
  }
  @Test func unknownDictionaryAndEmptyAudioNeverBecomeZeroOrAllWrong() throws {
    let unknown = try PronunciationComparison.compare(targets: [word("unknown", [])], heard: heard(["k"]), duration: 1)
    #expect(unknown.assessedWords == 0 && unknown.changedWords == 0)
    let empty = try PronunciationComparison.compare(targets: [word("cat", ["kæt"])], heard: [], duration: 1)
    #expect(empty.assessedWords == 0 && empty.changedWords == 0)
    #expect(PhoneInventory.parse("kæ☃t") == nil)
    #expect(PhoneInventory.fromARPAbet("B*") == nil)
  }
  @Test func ctcUsesActualPadAndCollapsesRepeatsWithoutDeletingAcrossBlank() throws {
    let ids = [124,116,116,124,116,0,118,124]
    var logits = Array(repeating: Float(-20), count: ids.count*127)
    for (frame,id) in ids.enumerated() { logits[frame*127+id] = 20 }
    let result = try BuddyPronunciationAdapter.decode(logits, frames: ids.count, width: 127,
      tokens: [124:"[PAD]", 0:" ", 116:"V", 118:"W"], duration: 1)
    #expect(result.map(\.symbol) == ["v","v","w"])
    #expect(result[0].end > result[0].start)
    logits[0] = .nan
    #expect(throws: BuddyError.self) {
      try BuddyPronunciationAdapter.decode(logits, frames: ids.count, width: 127, tokens: [:], duration: 1)
    }
  }
  @Test func sourceMisrecognitionIsNotBlamedOnLearner() throws {
    let targets = [word("wear", ["wɛə"]), word("vest", ["vɛst"])]
    let source = try PronunciationComparison.compare(targets: targets, heard: heard(["w","ɛ","l","v","ɛ","s","t"]), duration: 1)
    let learner = try PronunciationComparison.compare(targets: targets, heard: heard(["w","ɛ","l","w","ɛ","s","t"]), duration: 1)
    let gated = PronunciationComparison.gate(learner, reference: source)
    #expect(gated.assessedWords == 1)
    #expect(gated.changedWords == 1)
    #expect(gated.words[0].differences.isEmpty)
    #expect(gated.words[0].phones.allSatisfy { $0.kind == .referenceUncertain })
    #expect(gated.words[1].differences.first?.expected == "v")
    #expect(gated.words[1].differences.first?.observed == "w")
  }

  @Test func oversizedPhoneSequenceIsRejectedBeforeAllocatingAlignment() {
    #expect(throws: ContentMatchingError.self) {
      try PronunciationComparison.compare(targets: [word("cat", ["kæt"])], heard: heard(Array(repeating: "k", count: 513)), duration: 1)
    }
  }
}
