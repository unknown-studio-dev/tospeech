import AVFAudio
import CoreMedia
import Foundation
import Speech

enum SpeechAnalyzerPreparationError: Error, LocalizedError, Sendable {
  case unavailable
  case unsupportedLocale(String)
  case assetsUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable: "Apple SpeechTranscriber is unavailable on this Mac."
    case .unsupportedLocale(let locale): "Apple SpeechTranscriber does not support \(locale) on this Mac."
    case .assetsUnavailable: "The Apple Speech language model is not installed. Connect to the internet and retry."
    }
  }
}

/// macOS 26's on-device model. No SFSpeechRecognizer, DictationTranscriber or cloud fallback.
actor AppleSpeechAnalyzerTranscriber: AudioTranscriptTranscribing {
  static func module(localeIdentifier: String) async throws -> SpeechTranscriber {
    guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerPreparationError.unavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier))
    else { throw SpeechAnalyzerPreparationError.unsupportedLocale(localeIdentifier) }
    return SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [],
      attributeOptions: [.audioTimeRange])
  }

  static func installAssets(for transcriber: SpeechTranscriber) async throws {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await request.downloadAndInstall()
      } onCancel: {
        request.progress.cancel()
      }
    }
    try Task.checkCancellation()
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw SpeechAnalyzerPreparationError.assetsUnavailable
    }
  }

  func prepareForComparison(localeIdentifier: String) async throws {
    let transcriber = try await Self.module(localeIdentifier: localeIdentifier)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw SpeechAnalyzerPreparationError.assetsUnavailable
    }
  }

  func prepare(localeIdentifier: String) async throws {
    let transcriber = try await Self.module(localeIdentifier: localeIdentifier)
    try await Self.installAssets(for: transcriber)
  }

  func transcribe(
    audioURL: URL, localeIdentifier: String,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> AudioTranscription {
    let transcriber = try await Self.module(localeIdentifier: localeIdentifier)
    try await Self.installAssets(for: transcriber)
    try Task.checkCancellation()
    let file = try AVAudioFile(forReading: audioURL)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    // Cancel the analyzer before awaiting the collector on error: its result
    // sequence may otherwise keep the parent task from unwinding.
    let collector = Task { try await Self.collect(transcriber, duration: duration, onProgress: onProgress) }
    return try await withTaskCancellationHandler {
      do {
        if let end = try await analyzer.analyzeSequence(from: file) {
          try await analyzer.finalizeAndFinish(through: end)
        } else {
          try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let words = try await collector.value
        try Task.checkCancellation()
        guard !words.isEmpty else { throw TranscriptPreparationError.emptyApple }
        return AudioTranscription(
          words: words, source: .appleSpeechAnalyzer,
          provenance: TranscriptionProvenance(
            engine: "Apple SpeechAnalyzer", model: "SpeechTranscriber",
            localeIdentifier: transcriber.selectedLocales.first?.identifier ?? localeIdentifier,
            runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString))
      } catch {
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        _ = try? await collector.value
        throw error
      }
    } onCancel: {
      collector.cancel()
      Task { await analyzer.cancelAndFinishNow() }
    }
  }

  private static func collect(
    _ transcriber: SpeechTranscriber, duration: Double,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> [TimedWord] {
    var words: [TimedWord] = []
    for try await result in transcriber.results {
      try Task.checkCancellation()
      words.append(contentsOf: timedWords(from: result.text, fallbackStart: result.range.start.seconds))
      if duration > 0 { onProgress(min(1, max(0, result.range.end.seconds / duration))) }
    }
    return words
  }

  /// Never distribute a phrase-level interval evenly among words. Unknown word timing stays unknown.
  nonisolated static func timedWords(from text: AttributedString, fallbackStart: Double) -> [TimedWord] {
    text.runs[\.audioTimeRange].flatMap { range, characters in
      let tokens = String(text[characters].characters).split(whereSeparator: \.isWhitespace)
      let start = range?.start.seconds ?? fallbackStart
      let end = range?.end.seconds ?? start
      let reliable = tokens.count == 1 && start.isFinite && end.isFinite && end > start && start >= 0
      let anchor = start.isFinite && start >= 0 ? start : max(0, fallbackStart)
      return tokens.map { TimedWord(text: String($0), start: anchor, end: reliable ? end : anchor) }
    }
  }
}
