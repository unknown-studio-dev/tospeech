import Foundation
import Testing
@testable import ToSpeech

private final class PhoneticXeusFixtureLocator: NSObject { }

@Suite struct PhoneticXeusTests {
  private func fixture(status: String = "correct", reason: String? = nil, start: Double = 0, end: Double = 0.2,
    sourceEnd: Double = 0.2, sourceStatus: String = "correct", licence: String? = nil,
    contrast: [String: Any]? = nil, referenceMatch: Bool? = nil, logMargin: Double = 2.5,
    takeStatus: String? = nil, policy: String = XeusReferenceDiagnostics.policyV2,
    state: String = "SUPPORTED") throws -> PhoneticXeusEvidence {
    let unit = "one:0", licensed = licence ?? "accepted"
    let diagnostic: [String: Any] = ["groupID": "g", "state": state, "lengthStatus": "NOT_SEPARATELY_ASSESSED",
      "sourceHypothesis": ["status": sourceStatus], "takeHypothesis": ["status": status],
      "unitID": unit, "licence": licensed]
    let row: [String: Any] = ["expected": "θ", "status": status, "reason": reason as Any? ?? NSNull(),
      "start": start, "end": end, "expectedProbability": 0.8, "logMargin": logMargin,
      "closestPhone": "s", "confidence": 0.9, "sourceStart": 0, "sourceEnd": sourceEnd, "sourceStatus": sourceStatus,
      "diagnostic": diagnostic, "unitID": unit, "licence": licensed,
      "referenceMatch": referenceMatch as Any? ?? NSNull(), "takeStatus": takeStatus as Any? ?? NSNull(),
      "contrast": contrast as Any? ?? NSNull()]
    func region(_ duration: Double) -> [String: Any] {
      ["start": 0, "end": duration, "startFrame": 0, "endFrame": Int((duration / 0.02).rounded()),
       "speechFrames": 1, "blankMean": 0.2, "topCandidates": [],
       "tokens": [["symbol": "θ", "startFrame": 0, "endFrame": 1, "posterior": 0.8]]]
    }
    let reference: [String: Any] = ["policy": policy, "groups": [[
      "id": "g", "members": [["wordID": "one", "phoneIndex": 0, "displayPhone": "θ"]], "shared": false,
      "source": region(sourceEnd), "take": region(end),
      "comparison": ["state": "UNCALIBRATED", "jsDistance": 0.1, "pathSteps": 1, "sequenceEditDistance": 0]]]]
    let data: [String: Any] = ["revision": PhoneticXeusPackage.revision, "policy": PhoneticXeusPackage.evidencePolicy,
      "mapping": PhoneticXeusPackage.mappingPolicy, "device": "cpu", "dtype": "float32", "duration": 0.3,
      "sourceDuration": 0.4, "sourceShape": [20,428], "takeShape": [15,428], "inferenceSeconds": 0.1,
      "loadSeconds": 0.2, "peakRSS": 1000, "recognizedPhones": [],
      "sourceRecognizedPhones": [], "reference": reference, "referencePolicy": policy,
      "words": [["id":"one", "variant":["θ"], "phones":[row]]]]
    return try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: data))
  }
  /// One licensed unit rendered as two display phones (a PAIRS unit): one group, one unitID.
  /// `expand_rows` copies one row per display phone, so both members carry IDENTICAL spans on
  /// both timelines — that is what the helper really emits and what `convert` must accept.
  private func pairFixture(unitID: String? = "one:0", policy: String = XeusReferenceDiagnostics.policyV2,
    state: String = "SUPPORTED_BY_REFERENCE_CLASS", licence: String = "classD") throws -> PhoneticXeusEvidence {
    func row(_ expected: String) -> [String: Any] {
      var diagnostic: [String: Any] = ["groupID": "g", "state": state, "lengthStatus": "NOT_SEPARATELY_ASSESSED",
        "sourceHypothesis": ["status": "correct"], "takeHypothesis": ["status": "correct"], "licence": licence]
      var value: [String: Any] = ["expected": expected, "status": "correct", "reason": NSNull(),
        "start": 0, "end": 0.2, "expectedProbability": 0.8, "logMargin": 2.5,
        "closestPhone": expected, "confidence": 0.9, "sourceStart": 0,
        "sourceEnd": 0.2, "sourceStatus": "correct", "licence": licence]
      if let unitID { diagnostic["unitID"] = unitID; value["unitID"] = unitID }
      value["diagnostic"] = diagnostic
      return value
    }
    let region: [String: Any] = ["start": 0, "end": 0.2, "startFrame": 0, "endFrame": 10,
      "speechFrames": 1, "blankMean": 0.2, "topCandidates": [],
      "tokens": [["symbol": "θ", "startFrame": 0, "endFrame": 1, "posterior": 0.8]]]
    let reference: [String: Any] = ["policy": policy, "groups": [[
      "id": "g", "members": [["wordID": "one", "phoneIndex": 0, "displayPhone": "θ"],
        ["wordID": "one", "phoneIndex": 1, "displayPhone": "s"]], "shared": true,
      "source": region, "take": region,
      "comparison": ["state": "UNCALIBRATED", "jsDistance": 0.1, "pathSteps": 1, "sequenceEditDistance": 0]]]]
    let data: [String: Any] = ["revision": PhoneticXeusPackage.revision, "policy": PhoneticXeusPackage.evidencePolicy,
      "mapping": PhoneticXeusPackage.mappingPolicy, "device": "cpu", "dtype": "float32", "duration": 0.3,
      "sourceDuration": 0.4, "sourceShape": [20,428], "takeShape": [15,428], "inferenceSeconds": 0.1,
      "loadSeconds": 0.2, "peakRSS": 1000, "recognizedPhones": [],
      "sourceRecognizedPhones": [], "reference": reference, "referencePolicy": policy,
      "words": [["id":"one", "variant":["θ","s"], "phones":[row("θ"), row("s")]]]]
    return try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: data))
  }
  private var target: PronunciationWordTarget {
    .init(id: "one", text: "th", variants: ["/θ/"], dictionarySources: ["test"], sourceStart: nil, sourceEnd: nil)
  }
  private var pairTarget: PronunciationWordTarget {
    .init(id: "one", text: "ths", variants: ["/θs/"], dictionarySources: ["test"], sourceStart: nil, sourceEnd: nil)
  }
  @Test func uncertaintyStaysNeutralAndNeverBecomesNearCorrect() throws {
    let word = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "referenceUncertain"), targets: [target])[0]
    #expect(word.phones[0].quality == .unassessed)
    #expect(word.phones[0].unassessedReason == .referenceUncertain)
    #expect(word.phones[0].score == nil)
    #expect(PronunciationDisplay.runs(ipa: word.referenceIPA, word: word).filter { $0.phoneID != nil }.allSatisfy { $0.quality == .unassessed })
  }
  @Test func substitutionRetainsExpectedUKIPAAndHasNoUSPercentage() throws {
    let word = try PhoneticXeusAdapter.convert(fixture(status: "likelyIncorrect"), targets: [target])[0]
    #expect(word.phones[0].expected == "θ")
    #expect(word.phones[0].observed == "s")
    #expect(word.phones[0].quality == .incorrect)
    #expect(word.inventory == UKPhoneInventory.version)
    #expect(word.phones[0].score == nil)
  }
  @Test func invalidRangesAndMismatchedTargetsCannotBecomeColoredResults() throws {
    let raw = try fixture(end: 9)
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(raw, targets: [target]) }
    let valid = try fixture()
    let other = PronunciationWordTarget(id: "two", text: "th", variants: ["/θ/"], dictionarySources: [], sourceStart: nil, sourceEnd: nil)
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(valid, targets: [other]) }
  }
  @Test func historicalEvidenceStillDecodesWithoutXeusFields() throws {
    let json = Data(#"{"words":[],"duration":1,"recognizedPhones":[]}"#.utf8)
    let old = try JSONDecoder().decode(PronunciationEvidence.self, from: json)
    #expect(old.phoneticXeus == nil)
    #expect(old.ukReference == nil)
  }
  @Test func referenceGatingAndItsIndependentTimelineAreValidated() throws {
    let badSource = try fixture(sourceEnd: 9)
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(badSource, targets: [target]) }
    let bypassedGate = try fixture(sourceStatus: "uncertain", licence: "accepted")
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(bypassedGate, targets: [target]) }
    // A source can be longer than the learner: never validate against take duration.
    let independent = try fixture(sourceEnd: 0.4)
    #expect(try PhoneticXeusAdapter.convert(independent, targets: [target]).count == 1)
  }
  @Test func runtimeUpgradeRetainsVerifiedWeightsAndCreatesNewProvenance() {
    let old = "PhoneticXeus · UK Experimental · \(PhoneticXeusPackage.revision) · \(PhoneticXeusPackage.weightHash) · old runtime"
    #expect(PhoneticXeusPackage.acceptsInstallationMarker(old))
    #expect(PhoneticXeusPackage.acceptsInstallationMarker(PhoneticXeusPackage.installationIdentity))
    #expect(!PhoneticXeusPackage.acceptsInstallationMarker(old.replacingOccurrences(of: PhoneticXeusPackage.weightHash, with: "wrong")))
    #expect(PronunciationAssessmentService.retryProvenance(old) == PhoneticXeusPackage.provenance)
    #expect(PronunciationAssessmentService.retryProvenance("UK Reference · old") == UKReferencePackage.provenance)
    #expect(PronunciationAssessmentService.retryProvenance("unknown") == "unknown")
  }
  @Test func diagnosticEvidenceSurvivesPersistenceWithoutBecomingAScore() throws {
    let original = try fixture()
    let decoded = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONEncoder().encode(original))
    #expect(decoded.reference == original.reference)
    #expect(decoded.words[0].phones[0].diagnostic?.groupID == "g")
    #expect(decoded.reference?.groups[0].source?.sequence == "θ")
    #expect(try PhoneticXeusAdapter.convert(decoded, targets: [target])[0].phones[0].score == nil)
  }
  @Test func malformedOrMissingNewDiagnosticsAreRejectedButOldHistoryDecodes() throws {
    let original = try fixture()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "reference")
    object.removeValue(forKey: "sourceRecognizedPhones")
    let old = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.reference == nil)
    #expect(old.words[0].phones[0].expected == "θ")
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(old, targets: [target]) }
    object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var reference = try #require(object["reference"] as? [String: Any])
    var groups = try #require(reference["groups"] as? [[String: Any]])
    var source = try #require(groups[0]["source"] as? [String: Any])
    source["endFrame"] = 900
    groups[0]["source"] = source; reference["groups"] = groups; object["reference"] = reference
    let malformed = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(malformed, targets: [target]) }
  }
  @Test func v5EvidenceFieldsDecodeAndHistoricalRowsStillDecode() throws {
    let json = #"{"expected":"ɑː","status":"correct","reason":"contrastHead","unitID":"w:2","licence":"head","licensedRealization":null,"referenceStatus":"uncertain","takeStatus":"uncertain","takeReason":"ambiguous","referenceMatch":true,"contrast":{"name":"ɑː-æ","pUK":0.94,"decision":"uk"}}"#
    let row = try JSONDecoder().decode(PhoneticXeusPhoneEvidence.self, from: Data(json.utf8))
    #expect(row.licence == "head"); #expect(row.contrast?.decision == "uk"); #expect(row.referenceMatch == true)
    let old = try JSONDecoder().decode(PhoneticXeusPhoneEvidence.self, from: Data(#"{"expected":"θ","status":"uncertain"}"#.utf8))
    #expect(old.licence == nil && old.contrast == nil)
    #expect(PhoneAssessmentAvailability.referenceUnmapped.title == "review.availability.referenceUnmapped")
  }
  @Test func licensedReferenceAllowsGradingWithoutSourceCorrect() throws {
    let word = try PhoneticXeusAdapter.convert(fixture(sourceStatus: "uncertain", licence: "classD", state: "SUPPORTED_BY_REFERENCE_CLASS"), targets: [target])[0]
    #expect(word.phones[0].quality == .correct)
    let head = try PhoneticXeusAdapter.convert(fixture(sourceStatus: "likelyIncorrect", licence: "head", contrast: ["name": "ɑː-æ", "pUK": 0.91, "decision": "uk"], state: "SUPPORTED_BY_CONTRAST_HEAD"), targets: [target])[0]
    #expect(head.phones[0].quality == .correct)
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(fixture(sourceStatus: "uncertain", licence: "accepted"), targets: [target]) }
  }
  @Test func newReasonsMapToAvailabilityAndYellowIsNarrow() throws {
    let unmapped = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "referenceUnmapped", licence: "unmapped", state: "REFERENCE_UNMAPPED"), targets: [target])[0]
    #expect(unmapped.phones[0].unassessedReason == .referenceUnmapped)
    let cannot = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "modelCannotDistinguish", licence: "cannotDistinguish", state: "MODEL_CANNOT_DISTINGUISH"), targets: [target])[0]
    #expect(cannot.phones[0].unassessedReason == .modelCannotDistinguish)
    let yellow = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "ambiguous", referenceMatch: true, logMargin: 1.0, takeStatus: "uncertain", state: "INSUFFICIENT_EVIDENCE"), targets: [target])[0]
    #expect(yellow.phones[0].quality == .nearCorrect); #expect(yellow.phones[0].kind == .scored)
    let grey = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "ambiguous", referenceMatch: false, logMargin: 1.0, takeStatus: "uncertain", state: "INSUFFICIENT_EVIDENCE"), targets: [target])[0]
    #expect(grey.phones[0].quality == .unassessed)
    let ambiguousHead = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "ambiguous", contrast: ["name": "ɒ-ɑ+ɒ-ɔː", "pUK": 0.5, "decision": "ambiguous"], state: "INSUFFICIENT_EVIDENCE"), targets: [target])[0]
    #expect(ambiguousHead.phones[0].quality == .nearCorrect)
    // The head writes its contrast block before the reference gate runs. A row the gate then
    // demoted is not assessed at all, so its stale ambiguous decision must never colour it yellow.
    let gated = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "referenceWeak",
      licence: "weak", contrast: ["name": "ɒ-ɑ+ɒ-ɔː", "pUK": 0.5, "decision": "ambiguous"],
      state: "REFERENCE_WEAK"), targets: [target])[0]
    #expect(gated.phones[0].quality == .unassessed)
    #expect(gated.phones[0].unassessedReason == .referenceWeak)
    let unavailable = try PhoneticXeusAdapter.convert(fixture(status: "unavailable", reason: "referenceUnmapped",
      licence: "unmapped", contrast: ["name": "ɒ-ɑ+ɒ-ɔː", "pUK": 0.5, "decision": "ambiguous"],
      state: "REFERENCE_UNMAPPED"), targets: [target])[0]
    #expect(unavailable.phones[0].quality == .unassessed)
    #expect(unavailable.phones[0].unassessedReason == .referenceUnmapped)
  }
  /// Golden decode of a REAL helper result containing a PAIRS unit (/ə ɹ/ of "around"), produced by
  /// `runtime.assemble_from_logits`. Its two rows share one unitID and one span on both timelines;
  /// before the pair rule that combination failed the monotonic-timeline check and killed the job.
  @Test func realHelperOutputWithAPairUnitConvertsWithoutBreakingTheTimeline() throws {
    let bundle = Bundle(for: PhoneticXeusFixtureLocator.self)
    let url = try #require(bundle.url(forResource: "pair-unit-result", withExtension: "json"))
    let raw = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: Data(contentsOf: url))
    #expect(raw.revision == PhoneticXeusPackage.revision)
    #expect(raw.policy == PhoneticXeusPackage.evidencePolicy)
    #expect(raw.mapping == PhoneticXeusPackage.mappingPolicy)
    let around = PronunciationWordTarget(id: "w0", text: "around", variants: ["/əɹaʊnd/"],
      dictionarySources: ["test"], sourceStart: nil, sourceEnd: nil)
    let rows = raw.words[0].phones
    #expect(rows[0].unitID != nil && rows[0].unitID == rows[1].unitID)
    #expect(rows[0].unitID != rows[2].unitID)
    #expect(rows[0].sourceStart == rows[1].sourceStart && rows[0].sourceEnd == rows[1].sourceEnd)
    #expect(rows.allSatisfy { $0.referenceRealization != nil })
    let word = try PhoneticXeusAdapter.convert(raw, targets: [around])[0]
    #expect(word.phones.count == 5)
    #expect(word.phones.map(\.expected) == ["ə", "ɹ", "aʊ", "n", "d"])
    #expect(word.phones[0].start == word.phones[1].start)
    #expect(word.phones[0].end == word.phones[1].end)
    #expect(word.phones[0].start != nil)
  }
  @Test func v1HistoryStillConvertsAndV2RejectsUnknownStates() throws {
    #expect(try PhoneticXeusAdapter.convert(fixture(policy: XeusReferenceDiagnostics.policy), targets: [target]).count == 1)
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(fixture(state: "MADE_UP"), targets: [target]) }
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(fixture(licence: "bogus"), targets: [target]) }
  }
  @Test func onePairedUnitStaysGradedWhileSharingAcrossUnitsDoesNot() throws {
    let paired = try PhoneticXeusAdapter.convert(pairFixture(), targets: [pairTarget])[0]
    #expect(paired.phones.map(\.quality) == [.correct, .correct])
    // Without unit identity every shared member is a separate sound: the old rule still applies.
    #expect(throws: (any Error).self) {
      try PhoneticXeusAdapter.convert(pairFixture(unitID: nil, policy: XeusReferenceDiagnostics.policy, state: "SUPPORTED"), targets: [pairTarget])
    }
  }
  @Test func rowAndDiagnosticLicenceMustAgree() throws {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture(licence: "head"))) as? [String: Any])
    var words = try #require(object["words"] as? [[String: Any]])
    var phones = try #require(words[0]["phones"] as? [[String: Any]])
    var diagnostic = try #require(phones[0]["diagnostic"] as? [String: Any])
    diagnostic["licence"] = "weak"
    phones[0]["diagnostic"] = diagnostic; words[0]["phones"] = phones; object["words"] = words
    let mismatched = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(mismatched, targets: [target]) }
  }
  @Test func referenceNotConfidentAndAmbiguousSubstitutionMapToDistinctAvailability() throws {
    let notConfident = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "referenceNotConfident"), targets: [target])[0]
    #expect(notConfident.phones[0].quality == .unassessed)
    #expect(notConfident.phones[0].unassessedReason == .referenceNotConfident)
    let ambiguousSubstitution = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "ambiguousSubstitution"), targets: [target])[0]
    #expect(ambiguousSubstitution.phones[0].quality == .unassessed)
    #expect(ambiguousSubstitution.phones[0].unassessedReason == .ambiguousSubstitution)
    #expect(PhoneAssessmentAvailability.referenceNotConfident.title == "review.availability.referenceNotConfident")
    #expect(PhoneAssessmentAvailability.ambiguousSubstitution.title == "review.availability.ambiguousSubstitution")
  }
  @Test func evidencePolicyAndMappingMatchTheWordGatedHelperAndOldStoredResultsStillDecode() throws {
    let raw = try fixture()
    #expect(raw.policy == "xeus-uk-decision-v6-word-gated")
    #expect(raw.policy == PhoneticXeusPackage.evidencePolicy)
    #expect(raw.mapping == "xeus-uk-inventory-v4")
    #expect(raw.mapping == PhoneticXeusPackage.mappingPolicy)
    #expect(try PhoneticXeusAdapter.convert(raw, targets: [target]).count == 1)
    // A result persisted under the previous policy/mapping ids must still decode through its
    // stored path (it is only ever displayed, never re-converted) even though `convert` would
    // now reject it as fresh evidence.
    let v5 = try fixture()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(v5)) as? [String: Any])
    object["policy"] = "xeus-uk-ctc-evidence-v5-units"
    object["mapping"] = "xeus-uk-inventory-v3"
    let oldRaw = try JSONDecoder().decode(PhoneticXeusEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(oldRaw.policy == "xeus-uk-ctc-evidence-v5-units")
    #expect(oldRaw.mapping == "xeus-uk-inventory-v3")
    #expect(throws: (any Error).self) { try PhoneticXeusAdapter.convert(oldRaw, targets: [target]) }
    let stored = PronunciationEvidence(words: [], duration: 1, recognizedPhones: [], phoneticXeus: oldRaw)
    let decodedStored = try JSONDecoder().decode(PronunciationEvidence.self, from: JSONEncoder().encode(stored))
    #expect(decodedStored.phoneticXeus?.policy == "xeus-uk-ctc-evidence-v5-units")
    #expect(decodedStored.phoneticXeus?.mapping == "xeus-uk-inventory-v3")
  }
  @Test func coverageKeepsYellowAssessedAndNamesModelLimits() throws {
    let yellow = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "ambiguous", referenceMatch: true,
      logMargin: 1.0, takeStatus: "uncertain", state: "INSUFFICIENT_EVIDENCE"), targets: [target])
    let yellowCoverage = PronunciationCoverage(PronunciationEvidence(words: yellow, duration: 0.3, recognizedPhones: []))
    #expect(yellowCoverage.counts[.nearCorrect] == 1)
    #expect(yellowCoverage.reasons.isEmpty)
    let limited = try PhoneticXeusAdapter.convert(fixture(status: "uncertain", reason: "modelCannotDistinguish",
      licence: "cannotDistinguish", state: "MODEL_CANNOT_DISTINGUISH"), targets: [target])
    let limitedCoverage = PronunciationCoverage(PronunciationEvidence(words: limited, duration: 0.3, recognizedPhones: []))
    #expect(limitedCoverage.reasons == [.modelCannotDistinguish: 1])
  }
}
