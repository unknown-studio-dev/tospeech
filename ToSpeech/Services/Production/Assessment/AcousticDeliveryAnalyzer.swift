import AVFAudio
import Foundation

/// Local signal comparison attached to the same pronunciation job. It does not
/// introduce another model, infer phonetic linking or produce a proficiency score.
actor AcousticDeliveryAnalyzer {
  func analyze(sourceURL: URL, span: AudioSpan, takeURL: URL,
    pronunciation: PronunciationEvidence) throws -> DeliveryEvidence {
    let sourceFile = try AVAudioFile(forReading: sourceURL)
    let takeFile = try AVAudioFile(forReading: takeURL)
    var source = try Self.track(samples: CoreMLWordAligner.samples(file: sourceFile, start: span.start, end: span.end))
    var take = try Self.track(samples: CoreMLWordAligner.samples(file: takeFile, start: 0,
      end: Double(takeFile.length) / takeFile.processingFormat.sampleRate))
    if let pitch = pronunciation.ukReference?.pitch {
      source = UKPitchEvidence.apply(pitch.source, to: source)
      take = UKPitchEvidence.apply(pitch.take, to: take)
    }
    if let vad = pronunciation.ukReference?.vad {
      source = UKVADEvidence.apply(vad.source, to: source)
      take = UKVADEvidence.apply(vad.take, to: take)
    }
    var result = DeliveryEvidence(source: source, take: take)
    if pronunciation.ukReference != nil { result.policy = "uk-reference-neural-comparison-v1" }
    result.pitchModel = pronunciation.ukReference?.pitch?.policy
    for word in pronunciation.words where word.supported {
      // UK head uncertainty describes vowel identity, not a failed CTC path.
      // Preserve those explicitly approximate spans for listening comparisons.
      let excluded: [PhoneDifference.Kind] = UKPhoneInventory.isUK(word.inventory)
        ? [.uncertain, .omission, .insertion] : [.uncertain, .referenceUncertain, .omission, .insertion]
      guard !word.phones.contains(where: { excluded.contains($0.kind) }),
        let start = word.target.sourceStart, let end = word.target.sourceEnd,
        let takeStart = word.phones.compactMap(\.start).min(), let takeEnd = word.phones.compactMap(\.end).max()
      else { continue }
      let sourceSpan = AudioSpan(start: start-span.start, end: end-span.start)
      let takeSpan = AudioSpan(start: takeStart, end: takeEnd)
      guard sourceSpan.isValid(duration: source.duration), takeSpan.isValid(duration: take.duration),
        sourceSpan.duration >= 0.08, takeSpan.duration >= 0.08,
        let sourceDB = Self.level(source, in: sourceSpan), let takeDB = Self.level(take, in: takeSpan) else { continue }
      result.words.append(.init(id: word.id, text: word.target.text, source: sourceSpan, take: takeSpan,
        sourceDB: sourceDB, takeDB: takeDB))
    }
    for pair in zip(pronunciation.words, pronunciation.words.dropFirst()) {
      guard let left = result.words.first(where: { $0.id == pair.0.id }),
        let right = result.words.first(where: { $0.id == pair.1.id }),
        right.source.start >= left.source.start, right.take.start >= left.take.start else { continue }
      let sourceRegion = AudioSpan(start: left.source.start, end: right.source.end)
      let takeRegion = AudioSpan(start: left.take.start, end: right.take.end)
      result.boundaries.append(.init(id: left.id, phrase: "\(left.text)‿\(right.text)",
        source: sourceRegion, take: takeRegion, sourcePause: Self.silence(source, in: sourceRegion),
        takePause: Self.silence(take, in: takeRegion)))
    }
    return result
  }

  /// Input is the shared decoder's mono 16 kHz PCM; bounded before DSP allocation.
  nonisolated static func track(samples: [Float]) throws -> DeliveryTrack {
    guard samples.count >= 640, samples.count <= 480_000, samples.allSatisfy(\.isFinite) else { throw BuddyError.invalidAudio }
    let duration = Double(samples.count) / 16_000
    // Low-pass before reducing to 8 kHz. The result is an exploratory acoustic
    // contour, not Praat's filtered-AC implementation or a validated stress model.
    var low = 0.0, reduced: [Double] = []
    for (index, sample) in samples.enumerated() {
      low += 0.35 * (Double(sample) - low)
      if index.isMultiple(of: 2) { reduced.append(low) }
    }
    let window = 480, hop = 160
    var points: [(time: Double, db: Double, hz: Double?)] = []
    if reduced.count >= window {
      for offset in stride(from: 0, through: reduced.count-window, by: hop) {
        try Task.checkCancellation()
        let frame = Array(reduced[offset..<(offset+window)])
        let mean = frame.reduce(0,+) / Double(window)
        let centered = frame.map { $0-mean }
        let energy = centered.reduce(0) { $0+$1*$1 } / Double(window)
        let db = 10 * log10(max(energy, 1e-12))
        points.append((Double(offset+window/2)/8000, db, db > -55 ? pitch(centered) : nil))
      }
    }
    guard !points.isEmpty else { throw BuddyError.invalidAudio }
    let levels = points.map(\.db).sorted()
    let peak = levels[min(levels.count-1, Int(Double(levels.count)*0.95))]
    let threshold = max(-55, peak-30)
    let active = points.filter { $0.db > threshold }
    let activeSpan = active.first.flatMap { first in active.last.map {
      AudioSpan(start: max(0, first.time-0.01), end: min(duration, $0.time+0.01))
    }}
    let pitches = points.filter { $0.db > threshold }.compactMap(\.hz).sorted()
    let median = pitches.isEmpty ? nil : pitches[pitches.count/2]
    let frames = points.map { point in DeliveryFrame(time: point.time,
      relativeDB: max(-60, point.db-peak),
      pitchSemitones: point.db > threshold ? point.hz.flatMap { hz in median.map { 12*log2(hz/$0) } } : nil) }
    var pauses: [AudioSpan] = [], silenceStart: Double?
    if let activeSpan {
      for point in points where point.time >= activeSpan.start && point.time <= activeSpan.end {
        if point.db <= threshold { if silenceStart == nil { silenceStart = point.time-0.01 } }
        else if let start = silenceStart {
          if point.time-0.01-start >= 0.18 { pauses.append(.init(start: start, end: point.time-0.01)) }
          silenceStart = nil
        }
      }
    }
    return .init(duration: duration, frames: frames, pauses: pauses, activeSpan: activeSpan)
  }

  private nonisolated static func pitch(_ frame: [Double]) -> Double? {
    let minLag = 18, maxLag = 123 // approximately 65–444 Hz
    var correlation = Array(repeating: 0.0, count: maxLag+2)
    for lag in minLag...maxLag {
      var dot = 0.0, a = 0.0, b = 0.0
      for i in 0..<(frame.count-lag) {
        dot += frame[i]*frame[i+lag]; a += frame[i]*frame[i]; b += frame[i+lag]*frame[i+lag]
      }
      correlation[lag] = dot / max(1e-12, sqrt(a*b))
    }
    guard let best = correlation[minLag...maxLag].max(), best >= 0.8 else { return nil }
    guard let lag = (minLag+1..<maxLag).first(where: {
      correlation[$0] >= max(0.8, best*0.94) && correlation[$0] >= correlation[$0-1] && correlation[$0] >= correlation[$0+1]
    }) else { return nil }
    let a = correlation[lag-1], b = correlation[lag], c = correlation[lag+1]
    let denominator = a-2*b+c
    let shift = abs(denominator) > 1e-9 ? min(0.5, max(-0.5, 0.5*(a-c)/denominator)) : 0
    return 8000 / (Double(lag)+shift)
  }

  private nonisolated static func level(_ track: DeliveryTrack, in span: AudioSpan) -> Double? {
    let values = track.frames.filter { $0.time >= span.start && $0.time <= span.end }.map(\.relativeDB).sorted()
    return values.count >= 3 ? values[values.count/2] : nil
  }
  private nonisolated static func silence(_ track: DeliveryTrack, in span: AudioSpan) -> Double {
    track.pauses.reduce(0) { $0 + max(0, min(span.end, $1.end)-max(span.start, $1.start)) }
  }
}
