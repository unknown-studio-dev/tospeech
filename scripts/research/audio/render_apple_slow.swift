import AVFAudio
import Foundation

// Standalone, offline comparison tool. Never captures the microphone.
let args = CommandLine.arguments
guard args.count == 5, let rate = Float(args[3]), let overlap = Float(args[4]),
  (0.25...1).contains(rate), (3...32).contains(overlap) else {
  fatalError("usage: render-apple input.wav output.wav rate overlap")
}
let input = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let format = input.processingFormat
let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
pitch.rate = rate
pitch.pitch = 0
pitch.overlap = overlap
engine.attach(player); engine.attach(pitch)
engine.connect(player, to: pitch, format: format)
engine.connect(pitch, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
player.scheduleFile(input, at: nil)
try engine.start(); player.play()
let latency = Int((pitch.latency * format.sampleRate).rounded())
let wanted = Int((Double(input.length) / Double(rate)).rounded())
let total = wanted + latency + Int(format.sampleRate / 2)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
var channels = Array(repeating: [Float](), count: Int(format.channelCount))
var attempts = 0
while channels[0].count < total {
  attempts += 1
  guard attempts < total else { fatalError("renderer made no progress") }
  let status = try engine.renderOffline(AVAudioFrameCount(min(1024, total - channels[0].count)), to: buffer)
  switch status {
  case .success, .insufficientDataFromInputNode:
    guard let pcm = buffer.floatChannelData, buffer.frameLength > 0 else { continue }
    for c in channels.indices { channels[c] += Array(UnsafeBufferPointer(start: pcm[c], count: Int(buffer.frameLength))) }
  case .cannotDoInCurrentContext: continue
  case .error: fatalError("offline render failed")
  @unknown default: fatalError("unknown render status")
  }
}
engine.stop()
// Save the drained render too, so latency/tail checks cannot be hidden by trim.
func write(_ path: String, start: Int, count: Int) throws {
  let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
  pcm.frameLength = AVAudioFrameCount(count)
  for c in channels.indices {
    channels[c].withUnsafeBufferPointer { source in
      pcm.floatChannelData![c].update(from: source.baseAddress! + start, count: count)
    }
  }
  try file.write(from: pcm)
}
try write(args[2], start: latency, count: wanted)
try write(args[2] + ".drained.wav", start: 0, count: channels[0].count)
let active = channels[0].indices.filter { abs(channels[0][$0]) > 0.001 }
print("rate=\(rate) overlap=\(overlap) latencyFrames=\(latency) expected=\(wanted) active=\(active.first ?? -1)..<\(active.last ?? -1)")
