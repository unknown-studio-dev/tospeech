import AVFoundation
import CoreML
import Foundation

/// Bounded, sequential English CTC alignment. The model is bundled and never
/// fetched on a word click. ASR text, selection and raw timestamps stay intact.
actor CoreMLWordAligner: WordAlignmentAdapter {
  private let directory: URL
  private var busy = false
  init(directory: URL = Bundle.main.resourceURL!.appendingPathComponent("Alignment")) {
    self.directory = directory
  }

  func align(_ request: WordAlignmentRequest) async throws -> WordAlignmentResult {
    guard !busy else { throw WordAlignmentError.busy }
    busy = true
    defer { busy = false }
    try Task.checkCancellation()
    let url = directory.appendingPathComponent("EnglishAlignment.mlmodelc")
    guard FileManager.default.fileExists(atPath: url.path) else { throw WordAlignmentError.modelUnavailable }
    let vocabulary = try JSONDecoder().decode([String: Int].self,
      from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
    guard vocabulary["<pad>"] == 0, vocabulary["|"] == 4, vocabulary.count == 32 else { throw WordAlignmentError.invalidOutput }
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndGPU
    let model = try await MLModel.load(contentsOf: url, configuration: config)
    let file = try AVAudioFile(forReading: request.audioURL)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    var output = Array<TimedWord?>(repeating: nil, count: request.words.count)
    // Use existing ASR anchors only for context windows, not the final boundaries.
    var cursor = 0
    while cursor < request.words.count {
      try Task.checkCancellation()
      let first = request.words[cursor]
      guard first.start.isFinite, first.end.isFinite, first.start >= 0,
        first.end > first.start, first.end <= duration, Self.supports(first.text, vocabulary: vocabulary) else { cursor += 1; continue }
      var contextCursor = cursor
      while contextCursor > max(0, cursor - 2),
        request.words[contextCursor - 1].start.isFinite, request.words[contextCursor - 1].end.isFinite,
        request.words[contextCursor].start - request.words[contextCursor - 1].end < 1.2,
        Self.supports(request.words[contextCursor - 1].text, vocabulary: vocabulary) {
        contextCursor -= 1
      }
      let start = max(0, request.words[contextCursor].start - 0.4)
      var limit = cursor + 1
      while limit < request.words.count {
        let next = request.words[limit]
        guard next.start.isFinite, next.end.isFinite, next.start >= first.start,
          next.end > next.start, min(next.end, next.start + 2) + 0.4 - start <= 29,
          next.start - request.words[limit - 1].end < 1.2, Self.supports(next.text, vocabulary: vocabulary) else { break }
        limit += 1
      }
      let last = request.words[limit - 1]
      let end = min(duration, min(last.end, last.start + 2) + 0.4)
      guard end > start, end - start <= 30 else { cursor = limit; continue }
      let words = Array(request.words[contextCursor..<limit])
      let aligned = try alignChunk(words, start: start, end: end, file: file, model: model, vocabulary: vocabulary,
        sentenceStarts: Set(request.sentenceStartIndices.filter { contextCursor <= $0 && $0 < limit }.map { $0 - contextCursor }))
      let ownedEnd = limit < request.words.count && limit - cursor > 4 ? limit - 2 : limit
      for index in cursor..<ownedEnd { output[index] = aligned[index - contextCursor] }
      cursor = ownedEnd
    }
    for index in output.indices.dropLast() {
      if let left = output[index], let right = output[index + 1], left.end > right.start {
        output[index] = nil
        output[index + 1] = nil
      }
    }
    let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
    return WordAlignmentResult(words: output, provenance: TranscriptionProvenance(
      engine: "CTC forced alignment", model: "facebook/wav2vec2-base-960h",
      localeIdentifier: "en", runtimeVersion: "CoreML fp16; ctc-v2-sentence-onset; " + (metadata?["source_revision"] ?? "unknown")))
  }

  private static func supports(_ text: String, vocabulary: [String: Int]) -> Bool {
    let normalized = text.uppercased().replacingOccurrences(of: "’", with: "'")
      .filter { $0.isLetter || $0.isNumber || $0 == "'" }
    return !normalized.isEmpty && normalized.allSatisfy { vocabulary[String($0)] != nil }
  }

  private func alignChunk(_ words: [TimedWord], start: Double, end: Double,
    file: AVAudioFile, model: MLModel, vocabulary: [String: Int], sentenceStarts: Set<Int>
  ) throws -> [TimedWord?] {
    let empty = Array<TimedWord?>(repeating: nil, count: words.count)
    var labels: [Int] = []
    var wordLabels: [Range<Int>] = []
    for word in words {
      let normalized = word.text.uppercased().replacingOccurrences(of: "’", with: "'")
        .filter { $0.isLetter || $0.isNumber || $0 == "'" }
      guard !normalized.isEmpty else { wordLabels.append(labels.count..<labels.count); continue }
      // Unknown characters (e.g. digits) need spoken-form normalization; never
      // silently delete them and claim the remaining letters are aligned.
      let ids = normalized.compactMap { vocabulary[String($0)] }
      guard ids.count == normalized.count else { return empty }
      if !labels.isEmpty { labels.append(vocabulary["|"]!) }
      let begin = labels.count
      labels.append(contentsOf: ids)
      wordLabels.append(begin..<labels.count)
    }
    guard !labels.isEmpty, labels.count <= 1024 else { return empty }
    let samples = try Self.samples(file: file, start: start, end: end)
    guard samples.count >= 400 else { return empty }
    let input = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
    let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    let variance = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(samples.count)
    guard variance > 1e-10 else { return empty }
    let divisor = sqrt(variance + 1e-7)
    for i in samples.indices { input[i] = NSNumber(value: (Double(samples[i]) - mean) / divisor) }
    try Task.checkCancellation()
    let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
    try Task.checkCancellation()
    guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue,
      logits.shape.count == 3, logits.shape[0].intValue == 1, logits.shape[2].intValue == vocabulary.count,
      logits.shape[1].intValue == (samples.count - 400) / 320 + 1
    else { throw WordAlignmentError.invalidOutput }
    let frames = logits.shape[1].intValue, width = logits.shape[2].intValue
    var probabilities: [[Float]] = []
    for t in 0..<frames {
      let row = (0..<width).map { logits[[0, NSNumber(value: t), NSNumber(value: $0)]].floatValue }
      guard row.allSatisfy(\.isFinite), let maximum = row.max() else { throw WordAlignmentError.invalidOutput }
      let normalizer = maximum + log(row.reduce(Float(0)) { $0 + exp($1 - maximum) })
      probabilities.append(row.map { $0 - normalizer })
    }
    guard let spans = try CTCAlignment.align(logProbabilities: probabilities, labels: labels) else { return empty }
    return words.indices.map { index in
      let range = wordLabels[index]
      guard let first = range.first, let last = range.last else { return nil }
      // CTC characters are emission peaks, not whole spoken sounds. Space
      // emissions supply the boundary between adjacent words; retain blank
      // frames between characters and that boundary instead of clipping there.
      let begin: Double
      let peakStart = start + Double(spans[first].start) * 0.02
      if first > 0, labels[first - 1] == vocabulary["|"] {
        let separator = start + Double(spans[first - 1].start + spans[first - 1].end) * 0.01
        begin = sentenceStarts.contains(index)
          ? CTCSentenceOnset.start(observedStart: words[index].start, firstEmission: peakStart,
              precedingBoundary: separator, chunkStart: start)
          : separator
      } else {
        begin = CTCSentenceOnset.start(observedStart: words[index].start, firstEmission: peakStart,
          precedingBoundary: nil, chunkStart: start)
      }
      let finish: Double
      if last + 1 < labels.count, labels[last + 1] == vocabulary["|"] {
        finish = start + Double(spans[last + 1].start + spans[last + 1].end) * 0.01
      } else { finish = min(end, start + Double(spans[last].end) * 0.02 + 0.08) }
      // Local acoustic support plus bounded movement reject unrelated transcripts.
      // This threshold is a quality gate, not a calibrated confidence percentage.
      let support = range.map { label in
        (spans[label].start..<spans[label].end).map { probabilities[$0][labels[label]] }.max() ?? -.infinity
      }.reduce(Float(0), +) / Float(range.count)
      guard support > -2.5, finish > begin,
        abs(begin - words[index].start) <= 0.75,
        abs(finish - words[index].end) <= max(0.75, words[index].end - words[index].start > 2 ? 8 : 0)
      else { return nil }
      return TimedWord(text: words[index].text, start: begin, end: finish)
    }
  }

  nonisolated static func samples(file: AVAudioFile, start: Double, end: Double) throws -> [Float] {
    let format = file.processingFormat
    let startFrame = AVAudioFramePosition((start * format.sampleRate).rounded())
    let count = AVAudioFrameCount(min(file.length - startFrame, AVAudioFramePosition(((end - start) * format.sampleRate).rounded())))
    guard count > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
      let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
      let converter = AVAudioConverter(from: format, to: destinationFormat)
    else { throw WordAlignmentError.invalidAudio }
    file.framePosition = startFrame
    // A decoder may deliver fewer frames than requested even before EOF.
    guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(4096, count)) else { throw WordAlignmentError.invalidAudio }
    var read: AVAudioFrameCount = 0
    while read < count {
      try file.read(into: chunk, frameCount: min(chunk.frameCapacity, count-read))
      guard chunk.frameLength > 0 else { throw WordAlignmentError.invalidAudio }
      let input = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
      let destination = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
      let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
      for index in input.indices {
        guard let from = input[index].mData, let to = destination[index].mData else { throw WordAlignmentError.invalidAudio }
        memcpy(to.advanced(by: Int(read)*bytesPerFrame), from, Int(chunk.frameLength)*bytesPerFrame)
      }
      read += chunk.frameLength
    }
    source.frameLength = read
    guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 4096) else { throw WordAlignmentError.invalidAudio }
    let inputSource = ConversionInput(source)
    var samples: [Float] = []
    let expectedCount = Int(ceil(Double(source.frameLength) * 16000 / format.sampleRate))
    // AVAudioConverter may return .haveData before its buffered tail is drained.
    // Keep pulling until endOfStream instead of treating the first block as the clip.
    for _ in 0..<(expectedCount/4096 + 32) {
      output.frameLength = 0
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { requested, status in
        inputSource.pull(requested: requested, status)
      }
      if let error { throw error }
      guard let channel = output.floatChannelData?[0] else { throw WordAlignmentError.invalidAudio }
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
      if status == .endOfStream {
        guard abs(samples.count-expectedCount) <= 2 else { throw WordAlignmentError.invalidAudio }
        return samples
      }
      guard status != .error, output.frameLength > 0 || status == .inputRanDry else { throw WordAlignmentError.invalidAudio }
    }
    throw WordAlignmentError.invalidAudio
  }
}

/// AVAudioConverter pulls synchronously; the lock also makes the callback safe
/// under the SDK's Sendable contract. The buffer never escapes conversion.
private final class ConversionInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var position: AVAudioFrameCount = 0
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func pull(requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard position < buffer.frameLength, requested > 0 else { status.pointee = .endOfStream; return nil }
    let count = min(requested, buffer.frameLength-position)
    guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
      status.pointee = .noDataNow; return nil
    }
    chunk.frameLength = count
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    for index in source.indices {
      guard let from = source[index].mData, let to = destination[index].mData else {
        status.pointee = .noDataNow; return nil
      }
      memcpy(to, from.advanced(by: Int(position)*bytesPerFrame), Int(count)*bytesPerFrame)
    }
    position += count
    status.pointee = .haveData
    return chunk
  }
}
