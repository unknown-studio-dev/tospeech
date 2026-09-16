import Foundation

/// A tiny logistic head on a XEUS encoder mid-layer for RP contrasts the CTC head collapses (BATH
/// ɑː/æ, LOT ɒ/ɑ, ɒ/ɔː) — a 1:1 port of `scripts/assessment/phoneticxeus/uk_contrast_head.py` lines
/// 7-50 (module constants, `sigmoid`, `ContrastHead.__init__`/`load`/`probability`/`decide`).
///
/// The head never decides alone: `XeusRuntime` (a later task) only consults it when the CTC
/// competitor sits inside `COMPETITORS[phone]` — everywhere else the CTC decision stands on its
/// own. This port carries ONLY the head math; wiring the encoder's pooled hidden state into it is
/// a later task's job (see that task's note on `XeusOnnxSession`'s second `hidden` output).
struct XeusContrastHead {
  /// Port of `VERSION='uk-contrast-head-v1'` (line 8) — the only `data['version']` `load` accepts.
  private static let version = "uk-contrast-head-v1"

  /// Port of `HEAD_FILE='uk-contrast-head.json'` (line 7) — the resource file name. `load` takes a
  /// `URL` directly; resolving that URL against the app bundle/package resource dir is a later
  /// task's job (this port is agnostic to where the JSON comes from).
  static let HEAD_FILE = "uk-contrast-head.json"

  /// Port of `COMPETITORS` (line 9) — the CTC competitor symbols that route a decision through
  /// this head instead of standing on the CTC score alone.
  static let COMPETITORS: [String: Set<String>] = [
    "ɑː": ["a", "ã", "æ", "æ̃"],
    "ɒ": ["a", "o", "ɑ", "ɑ̃", "ɔ", "ɔ̃", "ʌ", "ʌ̃"],
  ]

  /// Port of `US_LABEL` (line 10) — the US-accent label the CTC head would otherwise emit for a
  /// contrast phone.
  static let US_LABEL: [String: String] = [
    "ɑː": "æ",
    "ɒ": "ɑ",
  ]

  /// Port of `CONTRASTS_FOR` (line 11) — which named logistic contrast(s) gate a given UK phone.
  /// `probability` takes the MIN across all of them, so a phone only reads "uk" if it wins EVERY
  /// contrast it's part of (`ɒ` must beat both `ɒ-ɑ` and `ɒ-ɔː`).
  static let CONTRASTS_FOR: [String: [String]] = [
    "ɑː": ["ɑː-æ"],
    "ɒ": ["ɒ-ɑ", "ɒ-ɔː"],
  ]

  /// Port of `LOW,HIGH=.30,.70` (line 12).
  private static let low = 0.30
  private static let high = 0.70

  /// One `self.contrasts[name]` entry (`__init__`, lines 33-36): standardized-logistic weights for
  /// a single named contrast.
  private struct Contrast {
    let mean: [Double]
    let scale: [Double]
    let w: [Double]
    let b: Double
  }

  /// JSON layout of `uk-contrast-head.json`: `{"version","layer","dim","contrasts":
  /// {name:{"mean","scale","w","b"}},"training":{...}}`. `training` is diagnostic-only metadata
  /// (clip/voice counts, cross-validation scores) and is not decoded here — `JSONDecoder` silently
  /// ignores JSON keys with no matching property.
  private struct HeadJSON: Decodable {
    struct ContrastJSON: Decodable { let mean: [Double]; let scale: [Double]; let w: [Double]; let b: Double }
    let version: String
    let layer: Int
    let dim: Int
    let contrasts: [String: ContrastJSON]
  }

  /// Port of `self.layer=int(data['layer'])`.
  let layer: Int
  /// Port of `self.dim=int(data['dim'])`.
  let dim: Int
  private let contrasts: [String: Contrast]

  /// Port of `ContrastHead.load(path)` (lines 38-42): `try: ... except Exception: return None`
  /// around `cls(json.loads(raw), hashlib.sha256(raw).hexdigest())`. This port drops the unused
  /// `sha256` digest — `probability`/`decide` never read it, and it is out of scope for this task.
  ///
  /// Folds in `__init__`'s validation (lines 28-32): the version must equal `VERSION`; every
  /// `mean`/`scale`/`w` array must have exactly `dim` entries; every contrast name referenced by
  /// `CONTRASTS_FOR` must be present in `data['contrasts']`. Any failure — file read, JSON decode,
  /// or validation — returns `nil`, matching Python's blanket `except Exception: return None`.
  static func load(_ url: URL) -> XeusContrastHead? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let json = try? JSONDecoder().decode(HeadJSON.self, from: data) else { return nil }
    guard json.version == version else { return nil }
    var contrasts: [String: Contrast] = [:]
    for (name, c) in json.contrasts {
      guard c.mean.count == json.dim, c.scale.count == json.dim, c.w.count == json.dim else { return nil }
      contrasts[name] = Contrast(mean: c.mean, scale: c.scale, w: c.w, b: c.b)
    }
    for names in CONTRASTS_FOR.values {
      for name in names where contrasts[name] == nil { return nil }
    }
    return XeusContrastHead(layer: json.layer, dim: json.dim, contrasts: contrasts)
  }

  /// Port of `sigmoid(z)` (line 14): `1/(1+exp(-clip(z,-60,60)))`.
  private static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-max(-60, min(60, z)))) }

  /// Port of `probability(display, pooled)` (lines 43-47): standardize `pooled` per contrast
  /// (`(x-mean)/scale`), dot with `w`, add `b`, `sigmoid`, then take the MIN across every contrast
  /// gating `phone` (`CONTRASTS_FOR[phone]`) — mirrors `ps=[sigmoid(...) for c in (...)]; return
  /// float(min(ps))`.
  ///
  /// `pooled` arrives as `[Float]` — the ONNX hidden-state dtype (a later task wires it from a
  /// mean-pooled encoder layer). Every element is upcast to `Double` once at the top, so the rest
  /// of the arithmetic runs entirely in `Double`, matching Python's `np.asarray(pooled,np.float64)`;
  /// the only precision this port itself can lose relative to the Python reference is whatever the
  /// upstream float32 ONNX output already lost, not anything in this matmul/sigmoid.
  ///
  /// `probability`/`decide` are non-throwing, matching the interface this struct is required to
  /// expose. A `pooled` of the wrong length, or a `phone` this head has no contrast table for, are
  /// both caller bugs (every call site only ever passes `ɑː`/`ɒ` together with a `dim`-length
  /// pooled vector) — mirroring `XeusCTC.path`'s established convention in this codebase, both trap
  /// via `precondition` rather than silently returning a misleading `0.0`.
  func probability(_ phone: String, _ pooled: [Float]) -> Double {
    precondition(pooled.count == dim, "XeusContrastHead.probability: pooled shape \(pooled.count) != dim \(dim)")
    guard let names = Self.CONTRASTS_FOR[phone], !names.isEmpty else {
      preconditionFailure("XeusContrastHead.probability: unsupported phone \(phone)")
    }
    let x = pooled.map { Double($0) }
    var best = Double.infinity
    for name in names {
      let c = contrasts[name]!  // guaranteed present by `load`'s CONTRASTS_FOR validation
      var z = c.b
      for i in 0..<dim { z += ((x[i] - c.mean[i]) / c.scale[i]) * c.w[i] }
      best = min(best, Self.sigmoid(z))
    }
    return best
  }

  /// Port of `decide(p)` (line 49): `'uk' if p>=HIGH else 'us' if p<=LOW else 'ambiguous'`.
  static func decide(_ p: Double) -> String {
    p >= high ? "uk" : (p <= low ? "us" : "ambiguous")
  }
}
