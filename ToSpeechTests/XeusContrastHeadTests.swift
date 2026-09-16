import Foundation
import Testing
@testable import ToSpeech

/// Parity tests ported from `scripts/assessment/phoneticxeus/test_head.py`
/// (`test_probability_uses_min_over_contrasts_and_bands`, `test_missing_or_malformed_file_yields_none`,
/// `test_competitor_tables`, `test_shipped_head_artifact_is_valid_and_documented`), plus a
/// recomputed-from-Python parity cross-check of `probability` against the REAL shipped
/// `uk-contrast-head.json` (dim 1024) run through `/tmp/echolab-xeus-env/bin/python` +
/// `uk_contrast_head.py` — not just the tiny synthetic head Python's own suite uses.
@Suite struct XeusContrastHeadTests {
  // MARK: - fixture loading

  private func fixtureURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(relativePath)
  }

  /// Same as `fixtureURL`, but relative to the repo root (`ToSpeechTests/`'s parent) — used to
  /// reach `scripts/assessment/phoneticxeus/` without a `".."` path segment.
  private func repoRootURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(relativePath)
  }

  /// `ToSpeechTests/Fixtures/XeusNative/contrast-head-synthetic.json` — a Swift-side regeneration of
  /// `test_head.py`'s `synthetic_head(tmp, dim=8)` fixture (`layer=12`, `dim=8`, three contrasts
  /// `ɑː-æ`/`ɒ-ɑ`/`ɒ-ɔː` each a one-hot `w` at index 0/1/2 with `mean=0`, `scale=1`, `b=0`, so
  /// `probability` reduces to `sigmoid(4*x[seed])` per contrast).
  private func loadSyntheticHead() throws -> XeusContrastHead {
    let url = fixtureURL("Fixtures/XeusNative/contrast-head-synthetic.json")
    let head = XeusContrastHead.load(url)
    #expect(head != nil)
    return try #require(head)
  }

  /// `scripts/assessment/phoneticxeus/uk-contrast-head.json` — the real, committed, BUNDLED head
  /// weights (dim 1024). Loaded directly from its source path, per the Task 8 brief ("for tests,
  /// load the committed JSON directly") rather than duplicating a ~1024-dim JSON blob into Fixtures.
  private func loadShippedHead() throws -> XeusContrastHead {
    let url = repoRootURL("scripts/assessment/phoneticxeus/uk-contrast-head.json")
    let head = XeusContrastHead.load(url)
    #expect(head != nil)
    return try #require(head)
  }

  // MARK: test_probability_uses_min_over_contrasts_and_bands (+ ambiguous band, not in the Python test)

  @Test func probabilityUsesMinOverContrastsAndCoversAllDecisionBands() throws {
    let head = try loadSyntheticHead()
    #expect(head.layer == 12)
    #expect(head.dim == 8)

    var upAk = [Float](repeating: 0, count: 8); upAk[0] = 1
    #expect(head.probability("ɑː", upAk) > 0.9)

    var downAk = [Float](repeating: 0, count: 8); downAk[0] = -1
    #expect(head.probability("ɑː", downAk) < 0.1)

    // Must win BOTH `ɒ-ɑ` (index 1) and `ɒ-ɔː` (index 2) — index 1 alone would read confidently "uk".
    var mixedLot = [Float](repeating: 0, count: 8); mixedLot[1] = 1; mixedLot[2] = -1
    #expect(head.probability("ɒ", mixedLot) < 0.1)

    // x=0 -> z=0 -> sigmoid(0)=0.5 exactly -> the "ambiguous" band (not exercised by test_head.py,
    // which only checks the >.9 and <.1 extremes; added here for LOW/HIGH/ambiguous coverage).
    let zero = [Float](repeating: 0, count: 8)
    let midpoint = head.probability("ɑː", zero)
    #expect(abs(midpoint - 0.5) < 1e-9)
    #expect(XeusContrastHead.decide(midpoint) == "ambiguous")

    #expect(XeusContrastHead.decide(0.71) == "uk")
    #expect(XeusContrastHead.decide(0.3) == "us")
    #expect(XeusContrastHead.decide(0.5) == "ambiguous")
    // Boundary inclusivity: `p>=HIGH` and `p<=LOW` (not `>`/`<`).
    #expect(XeusContrastHead.decide(0.70) == "uk")
    #expect(XeusContrastHead.decide(0.30) == "us")
  }

  // MARK: test_missing_or_malformed_file_yields_none

  @Test func missingOrMalformedFileYieldsNil() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XeusContrastHeadTest-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(XeusContrastHead.load(dir.appendingPathComponent("nope.json")) == nil)

    let malformed = dir.appendingPathComponent(XeusContrastHead.HEAD_FILE)
    try Data(#"{"version":"x"}"#.utf8).write(to: malformed)
    #expect(XeusContrastHead.load(malformed) == nil)
  }

  // MARK: test_competitor_tables

  @Test func competitorAndLabelTables() {
    #expect(XeusContrastHead.HEAD_FILE == "uk-contrast-head.json")
    #expect(XeusContrastHead.COMPETITORS["ɑː"]?.contains("æ") == true)
    #expect(XeusContrastHead.COMPETITORS["ɒ"]?.contains("ɑ̃") == true)
    #expect(XeusContrastHead.US_LABEL["ɒ"] == "ɑ")
    #expect(XeusContrastHead.US_LABEL["ɑː"] == "æ")
    #expect(XeusContrastHead.CONTRASTS_FOR["ɑː"] == ["ɑː-æ"])
    #expect(XeusContrastHead.CONTRASTS_FOR["ɒ"] == ["ɒ-ɑ", "ɒ-ɔː"])
  }

  // MARK: test_shipped_head_artifact_is_valid_and_documented (scoped to load/layer/dim; the
  // cvByWord/cvByVoice/voices training-metadata assertions are out of scope for this port, which
  // only carries `probability`/`decide` math, not the training-metadata JSON fields).

  @Test func shippedHeadArtifactLoadsWithExpectedLayerAndDim() throws {
    let head = try loadShippedHead()
    #expect(head.layer == 13)
    #expect(head.dim == 1024)
  }

  // MARK: recomputed-from-Python parity (real shipped weights, synthetic pooled vectors)

  /// `pooled[i] = Float(i % 11) * Float(0.1) - Float(0.5)` — plain `Float` (binary32) arithmetic,
  /// bit-for-bit reproducible from the Python reference's `np.float32` computation of the same
  /// formula (see the Task 8 report for the recompute script), so upcasting to `Double` inside
  /// `probability` starts from an identical input on both sides.
  private func formulaA(_ dim: Int) -> [Float] {
    (0..<dim).map { i in Float(i % 11) * Float(0.1) - Float(0.5) }
  }

  /// `pooled[i] = Float((i*37) % 13 - 6) * Float(0.05)` — the modulo/subtraction happen in exact
  /// `Int` arithmetic (never overflowing, never negative before the final `-6`), matching Python's
  /// plain-`int` computation of `(i*37) % 13 - 6` before it is cast to `np.float32`.
  private func formulaB(_ dim: Int) -> [Float] {
    (0..<dim).map { i in Float((i * 37) % 13 - 6) * Float(0.05) }
  }

  @Test func probabilityMatchesPythonReferenceOnRealShippedWeights() throws {
    let head = try loadShippedHead()
    let dim = head.dim
    let zero = [Float](repeating: 0, count: dim)
    let a = formulaA(dim)
    let b = formulaB(dim)

    let cases: [(name: String, pooled: [Float], phone: String, expected: Double)] = [
      ("zero-ak", zero, "ɑː", 0.8933265938637268),
      ("zero-lot", zero, "ɒ", 0.07862906538200125),
      ("formulaA-ak", a, "ɑː", 0.9667431700810327),
      ("formulaA-lot", a, "ɒ", 0.046773985528621345),
      ("formulaB-ak", b, "ɑː", 0.8504269840814679),
      ("formulaB-lot", b, "ɒ", 0.06722888002747218),
    ]
    for c in cases {
      let actual = head.probability(c.phone, c.pooled)
      #expect(abs(actual - c.expected) < 1e-6, "\(c.name): \(actual) vs python \(c.expected)")
    }
  }
}
