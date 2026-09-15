import AVFoundation
import CoreML
import Foundation

struct Span { let start: Int; let end: Int }

func align(logProbabilities: [[Float]], labels: [Int], blank: Int = 0) -> [Span]? {
  guard !labels.isEmpty, !logProbabilities.isEmpty else { return nil }
  let states = labels.count * 2 + 1, frames = logProbabilities.count
  var previous = Array(repeating: -Float.infinity, count: states)
  previous[0] = 0
  var trace = Array(repeating: UInt8(0), count: states * frames)
  for t in 0..<frames {
    var current = Array(repeating: -Float.infinity, count: states)
    for s in 0..<states {
      let label = s.isMultiple(of: 2) ? blank : labels[s / 2]
      var score = previous[s], step: UInt8 = 0
      if s > 0, previous[s - 1] > score { score = previous[s - 1]; step = 1 }
      if s > 1, !s.isMultiple(of: 2), labels[s / 2] != labels[s / 2 - 1], previous[s - 2] > score {
        score = previous[s - 2]; step = 2
      }
      current[s] = score + logProbabilities[t][label]
      trace[t * states + s] = step
    }
    previous = current
  }
  var state = previous[states - 1] > previous[states - 2] ? states - 1 : states - 2
  guard previous[state].isFinite else { return nil }
  var starts = Array(repeating: frames, count: labels.count)
  var ends = Array(repeating: 0, count: labels.count)
  for t in (0..<frames).reversed() {
    if !state.isMultiple(of: 2) {
      starts[state / 2] = t
      ends[state / 2] = max(ends[state / 2], t + 1)
    }
    state -= Int(trace[t * states + state])
  }
  guard zip(starts, ends).allSatisfy({ $0 < $1 }) else { return nil }
  return zip(starts, ends).map(Span.init)
}

func samples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let sourceFormat = file.processingFormat
  guard let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
    let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat),
    let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
  else { throw NSError(domain: "align-words", code: 1) }
  try file.read(into: source)
  final class Input: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer; var sent = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  }
  let input = Input(source)
  var values: [Float] = []
  while true {
    guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 4096) else {
      throw NSError(domain: "align-words", code: 2)
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, status in
      if input.sent { status.pointee = .endOfStream; return nil }
      input.sent = true; status.pointee = .haveData; return input.buffer
    }
    if let error { throw error }
    guard let channel = output.floatChannelData?[0] else { throw NSError(domain: "align-words", code: 3) }
    values.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    if status == .endOfStream { return values }
  }
}

guard CommandLine.arguments.count == 5 else {
  fatalError("usage: align-words AUDIO TRANSCRIPT MODEL.mlmodelc VOCAB.json")
}
let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
let transcript = CommandLine.arguments[2]
let modelURL = URL(fileURLWithPath: CommandLine.arguments[3])
let vocabularyURL = URL(fileURLWithPath: CommandLine.arguments[4])
let vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabularyURL))
let words = transcript.uppercased().replacingOccurrences(of: "’", with: "'")
  .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
var labels: [Int] = [], ranges: [Range<Int>] = []
for word in words {
  if !labels.isEmpty { labels.append(vocabulary["|"]!) }
  let start = labels.count
  labels.append(contentsOf: word.compactMap { vocabulary[String($0)] })
  ranges.append(start..<labels.count)
}
let audio = try samples(audioURL)
let mean = audio.reduce(0.0) { $0 + Double($1) } / Double(audio.count)
let variance = audio.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(audio.count)
let input = try MLMultiArray(shape: [1, NSNumber(value: audio.count)], dataType: .float32)
for index in audio.indices { input[index] = NSNumber(value: (Double(audio[index]) - mean) / sqrt(variance + 1e-7)) }
let model = try MLModel(contentsOf: modelURL)
let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue else { fatalError("missing logits") }
let frames = logits.shape[1].intValue, width = logits.shape[2].intValue
var probabilities: [[Float]] = []
for frame in 0..<frames {
  let row = (0..<width).map { logits[[0, NSNumber(value: frame), NSNumber(value: $0)]].floatValue }
  let maximum = row.max()!
  let normalizer = maximum + log(row.reduce(Float(0)) { $0 + exp($1 - maximum) })
  probabilities.append(row.map { $0 - normalizer })
}
guard let spans = align(logProbabilities: probabilities, labels: labels) else { fatalError("alignment failed") }
var result: [[String: Any]] = []
for (index, range) in ranges.enumerated() {
  let begin: Double
  if let separator = range.first.map({ $0 - 1 }), separator >= 0, labels[separator] == vocabulary["|"] {
    begin = Double(spans[separator].start + spans[separator].end) * 0.01
  } else { begin = max(0, Double(spans[range.first!].start) * 0.02 - 0.12) }
  let finish: Double
  let separator = range.endIndex
  if separator < labels.count, labels[separator] == vocabulary["|"] {
    finish = Double(spans[separator].start + spans[separator].end) * 0.01
  } else { finish = min(Double(audio.count) / 16_000, Double(spans[range.last!].end) * 0.02 + 0.12) }
  result.append(["word": words[index].lowercased(), "start": begin, "end": finish])
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
