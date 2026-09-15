import Foundation
import Testing
@testable import ToSpeech

struct SourceLoudnessTests {
  private let report = """
    [Parsed_ebur128_0 @ 0x1] t: 837.9   TARGET:-23 LUFS    M: -25.1 S: -22.8     I: -21.9 LUFS       LRA:   9.3 LU
    [Parsed_ebur128_0 @ 0x1] Summary:

      Integrated loudness:
        I:         -21.9 LUFS
        Threshold: -32.4 LUFS

      Loudness range:
        LRA:         9.3 LU
        Threshold: -42.6 LUFS
        LRA low:   -27.6 LUFS
        LRA high:  -18.3 LUFS
    """

  @Test func readsTheIntegratedLoudnessFromTheSummaryOnly() {
    #expect(SourceLoudness.integratedLoudness(in: report) == -21.9)
    #expect(SourceLoudness.integratedLoudness(in: "I: -21.9 LUFS with no summary") == nil)
    #expect(SourceLoudness.integratedLoudness(in: "Integrated loudness:\n I: -70.0 LUFS") == -70)
    #expect(SourceLoudness.integratedLoudness(in: "") == nil)
  }

  @Test func gainReachesTheTargetWithinItsLimits() {
    #expect(abs(SourceLoudness.gainDB(measuredLUFS: -21.9) - 5.9) < 1e-9)
    #expect(SourceLoudness.gainDB(measuredLUFS: -16.3) == 0)
    #expect(SourceLoudness.gainDB(measuredLUFS: -40) == 12)
    #expect(SourceLoudness.gainDB(measuredLUFS: -12) == -4)
    #expect(SourceLoudness.gainDB(measuredLUFS: -70) == 0)
    #expect(SourceLoudness.gainDB(measuredLUFS: .nan) == 0)
  }

  @Test func encodeUsesLinearGainAndAPeakLimiterOnlyWhenNeeded() {
    let source = URL(fileURLWithPath: "/tmp/in.webm")
    let destination = URL(fileURLWithPath: "/tmp/source.m4a")
    #expect(SourceLoudness.filter(gainDB: 0) == nil)
    #expect(SourceLoudness.filter(gainDB: 5.9) == "volume=5.90dB,alimiter=limit=0.8913:attack=5:release=50:level=false")
    #expect(SourceLoudness.filter(gainDB: 0, minimumFrames: 96_000) == "apad=whole_len=96000")
    #expect(SourceLoudness.encodeArguments(source: source, destination: destination, gainDB: 0)
      == ["-y", "-i", "/tmp/in.webm", "-vn", "-c:a", "aac", "-b:a", "192k", "/tmp/source.m4a"])
    let levelled = SourceLoudness.encodeArguments(source: source, destination: destination, gainDB: -4, minimumFrames: 10)
    #expect(levelled.contains("-af"))
    #expect(levelled.last == "/tmp/source.m4a")
    #expect(SourceLoudness.measurementArguments(source: source).contains("ebur128"))
  }
}
