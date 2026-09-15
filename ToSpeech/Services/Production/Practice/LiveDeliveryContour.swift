import Foundation

/// Bridges in-progress capture (native rate mono PCM) to the shared acoustic
/// DSP without touching AcousticDeliveryAnalyzer. Linear resample is adequate:
/// track() low-passes before its own decimation, and this is an exploratory
/// contour, not a validated pitch measurement.
enum LiveDeliveryContour {
  static func resampleTo16k(_ samples: [Float], from rate: Double) -> [Float] {
    guard rate > 0, samples.count > 1 else { return samples }
    if abs(rate - 16_000) < 1 { return samples }
    let ratio = 16_000 / rate
    let outCount = Int(Double(samples.count) * ratio)
    guard outCount > 1 else { return [] }
    var out = [Float](); out.reserveCapacity(outCount)
    for i in 0..<outCount {
      let src = Double(i) / ratio
      let i0 = Int(src)
      let frac = Float(src - Double(i0))
      let a = samples[i0]
      let b = i0 + 1 < samples.count ? samples[i0 + 1] : a
      out.append(a + (b - a) * frac)
    }
    return out
  }

  static func track(monoSamples: [Float], inputSampleRate: Double) -> DeliveryTrack? {
    let resampled = resampleTo16k(monoSamples, from: inputSampleRate)
    guard resampled.count >= 640 else { return nil }
    return try? AcousticDeliveryAnalyzer.track(samples: resampled)
  }
}
