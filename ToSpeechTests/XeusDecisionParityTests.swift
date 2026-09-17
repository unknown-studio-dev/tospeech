import Foundation
import Testing
@testable import ToSpeech

/// Task 10's hard acceptance gate: run the full native scorer (`XeusOnnxScorer.assemble`, the
/// ORT-free decision core the ORT path also funnels through) on every golden fixture's saved logits
/// and assert per-phone status/reason and coverage match `<clip>.decisions.json` EXACTLY, plus the
/// native false-Sai=0 property (a source-self clip yields NO `likelyIncorrect`). Logits are injected
/// (ORT bypassed) so this is pure decision parity, independent of the ONNX graph.
@Suite struct XeusDecisionParityTests {
  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }

  private func shippedVocab() throws -> [String: Int] {
    let url = repoRoot.appendingPathComponent(
      "scripts/assessment/phoneticxeus/ipa_vocab.json")
    return try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
  }

  private func scorer() throws -> XeusOnnxScorer {
    // A dummy model URL: `assemble` never touches ORT/the graph. The real shipped vocab drives the
    // decision, head is nil (none of these clips realize a CONTRASTS_FOR phone outside its accepted
    // class, so the head plays no role — same rationale as XeusRuntimeTests' clip parity).
    XeusOnnxScorer(modelURL: URL(fileURLWithPath: "/dev/null/xeus.onnx"), vocab: try shippedVocab(), head: nil)
  }

  private func loadClip(_ name: String) throws -> [[Double]] {
    try XeusRuntimeTests.loadNpyF32(repoRoot.appendingPathComponent("ToSpeechTests/Fixtures/XeusNative/\(name)"))
  }

  private func golden(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: repoRoot.appendingPathComponent("ToSpeechTests/Fixtures/XeusNative/\(name)")))
      as! [String: Any]
  }

  private func request(from golden: [String: Any]) -> XeusRequest {
    let requestJSON = golden["request"] as! [String: Any]
    let words = (requestJSON["words"] as! [[String: Any]]).map { word in
      XeusRequest.Word(id: word["id"] as! String, text: word["text"] as! String,
        variants: (word["variants"] as! [[Any]]).map { $0.map { $0 as! String } })
    }
    return XeusRequest(words: words)
  }

  /// Asserts per-phone (expected/status/reason) and coverage parity against the golden decisions.
  private func assertParity(_ evidence: PhoneticXeusEvidence, golden: [String: Any], label: String) {
    let result = golden["result"] as! [String: Any]
    let goldenWords = result["words"] as! [[String: Any]]
    #expect(evidence.words.count == goldenWords.count, "\(label) word count")
    for (wi, goldenWord) in goldenWords.enumerated() {
      let goldenPhones = goldenWord["phones"] as! [[String: Any]]
      let phones = evidence.words[wi].phones
      #expect(phones.count == goldenPhones.count, "\(label) word \(wi) phone count")
      for (pi, goldenPhone) in goldenPhones.enumerated() where pi < phones.count {
        let phone = phones[pi]
        #expect(phone.expected == (goldenPhone["expected"] as! String), "\(label) w\(wi)p\(pi) expected")
        #expect(phone.status == (goldenPhone["status"] as! String), "\(label) w\(wi)p\(pi) status")
        #expect(phone.reason == (goldenPhone["reason"] as? String), "\(label) w\(wi)p\(pi) reason")
      }
    }
    let allPhones = evidence.words.flatMap { $0.phones }
    let correct = allPhones.filter { $0.status == "correct" }.count
    let incorrect = allPhones.filter { $0.status == "likelyIncorrect" }.count
    let coverage = result["coverage"] as! [String: Any]
    #expect(allPhones.count == (coverage["total"] as! NSNumber).intValue, "\(label) total")
    #expect(correct == (coverage["correct"] as! NSNumber).intValue, "\(label) correct")
    #expect(incorrect == (coverage["incorrect"] as! NSNumber).intValue, "\(label) incorrect")
  }

  /// Source-self parity + false-Sai=0: source==take, so no phone may be `likelyIncorrect`.
  private func assertSourceSelf(logits: String, decisions: String) async throws {
    let lp = try loadClip(logits)
    let g = try golden(decisions)
    let evidence = try await scorer().assemble(
      sourceLogits: lp, takeLogits: lp, hiddenSource: nil, hiddenTake: nil, request: request(from: g),
      sourceDuration: (g["sourceDuration"] as! NSNumber).doubleValue,
      takeDuration: (g["takeDuration"] as! NSNumber).doubleValue)
    assertParity(evidence, golden: g, label: logits)
    let incorrect = evidence.words.flatMap { $0.phones }.filter { $0.status == "likelyIncorrect" }.count
    #expect(incorrect == 0, "native false-Sai must be 0 for source-self \(logits), got \(incorrect)")
  }

  @Test func okaySourceSelfParityAndZeroFalseSai() async throws {
    try await assertSourceSelf(logits: "okay.logits.npy", decisions: "okay.decisions.json")
  }

  @Test func vestUKSourceSelfParityAndZeroFalseSai() async throws {
    try await assertSourceSelf(logits: "vest-uk.logits.npy", decisions: "vest-uk.decisions.json")
  }

  @Test func fullSourceSourceSelfParityAndZeroFalseSai() async throws {
    try await assertSourceSelf(logits: "full-source.logits.npy", decisions: "full-source.decisions.json")
  }

  /// A real /v/→/w/ substitution (source says "vest", take says "west"): exercises the take path and
  /// asserts the one expected `likelyIncorrect` matches the golden.
  @Test func vestVsWestSubstitutionParity() async throws {
    let source = try loadClip("vest-uk.logits.npy")
    let take = try loadClip("west-uk.logits.npy")
    let g = try golden("vest-uk-vs-west-uk.decisions.json")
    let evidence = try await scorer().assemble(
      sourceLogits: source, takeLogits: take, hiddenSource: nil, hiddenTake: nil, request: request(from: g),
      sourceDuration: (g["sourceDuration"] as! NSNumber).doubleValue,
      takeDuration: (g["takeDuration"] as! NSNumber).doubleValue)
    assertParity(evidence, golden: g, label: "vest-vs-west")
  }
}
