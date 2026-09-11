#if DEBUG
  import SwiftUI
  import AppKit
  import AVFAudio

  /// Developer-only export of app-owned views, including AppKit-backed scroll views.
  @MainActor enum PreviewRenderer {
    private static var previewLanguage: AppLanguage {
      guard let argument = ProcessInfo.processInfo.arguments.first(where: {
        $0.hasPrefix("--language=")
      }) else { return .deviceDefault }
      return AppLanguage(rawValue: String(argument.dropFirst(11))) ?? .deviceDefault
    }

    static func render() async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "EchoLabPreviews")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
      store.preferences.language = previewLanguage
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--word-timing-audit=") }) {
        guard let lessonID = UUID(uuidString: String(arg.dropFirst("--word-timing-audit=".count))) else { throw CocoaError(.coderInvalidValue) }
        let paths = BackendPaths.live
        let database = try ProductionDatabase(url: paths.database)
        let sentences = try await database.preparedPracticeSentences(lessonID: lessonID, paths: paths)
        var total = 0, available = 0, reviewed = 0, highlighted = 0
        for sentence in sentences {
          for token in sentence.tokens {
            total += 1
            if token.needsTimingReview { reviewed += 1 }
            if let range = ProductionWordTiming.range(for: token, in: sentence.target) {
              available += 1
              if ProductionWordTiming.playingWordID(at: range.lowerBound + range.count / 2,
                tokens: sentence.tokens, in: sentence.target) == token.id { highlighted += 1 }
            }
          }
        }
        if let sentence = sentences.first(where: { $0.tokens.contains(where: \.needsTimingReview) }),
          let token = sentence.tokens.first(where: \.needsTimingReview) {
          try await write(WordPronunciationView(sentence: sentence.lessonSentence(number: 1), wordID: token.id,
            onEditTiming: { _ in }, onClose: {}, usesPreviewReferenceAudio: false).environment(store),
            size: CGSize(width: 520, height: 526), name: "word-timing-review-\(previewLanguage.rawValue)", directory: directory)
        }
        print("WORD_TIMING_AUDIT: total=\(total), observed=\(available), review=\(reviewed), midpointHighlight=\(highlighted); immutable revisions unchanged; no recognition run")
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--parakeet-import-probe=") }) {
        let url = URL(fileURLWithPath: String(arg.dropFirst("--parakeet-import-probe=".count)))
        let root = directory.appendingPathComponent("ParakeetImport-\(UUID())")
        let paths = BackendPaths(root: root)
        try paths.prepare()
        let db = try ProductionDatabase(url: paths.database)
        let liveDB = try ProductionDatabase(url: BackendPaths.live.database)
        let adapter = ParakeetTranscriptionAdapter(database: liveDB, paths: .live)
        let importer = ProductionImportService(database: db, paths: paths, usesSpeechFallback: false,
          transcriptionAdapters: TranscriptionAdapterRegistry([adapter]))
        let started = Date()
        let job = try await importer.submit(.localAudio(url: url, securityScoped: false, titleOverride: "Parakeet integration probe"),
          transcriptionEngine: "parakeet", transcriptionModelID: TranscriptionSelection.parakeet.modelID, compareWithApple: false)
        for _ in 0..<1200 {
          if try await db.lesson(id: job.lessonID).lifecycle == .ready { break }
          if let failure = try await importer.importJobs().first(where: { $0.id == job.id && $0.phase == .failed }) {
            throw failure.error ?? ProductionImportError.recoveryRequired("Parakeet probe failed")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard try await db.lesson(id: job.lessonID).lifecycle == .ready else {
          await importer.cancel(jobID: job.id)
          throw ProductionImportError.recoveryRequired("Parakeet import probe timed out")
        }
        let sentences = try await ProductionPracticeService(database: db, paths: paths).preparedSentences(lessonID: job.lessonID)
        let hasSource = sentences.allSatisfy { $0.baseline.source == .parakeet && $0.baseline.transcription?.model == ParakeetTranscriptionAdapter.modelID }
        guard !sentences.isEmpty, hasSource else { throw CocoaError(.coderInvalidValue) }
        print("PARAKEET_IMPORT: ready; sentences=\(sentences.count); provenance=parakeet; noApple=true; elapsedSeconds=\(Date().timeIntervalSince(started)); root=\(root.path)")
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--parakeet-probe=") }) {
        let url = URL(fileURLWithPath: String(arg.dropFirst("--parakeet-probe=".count)))
        let paths = BackendPaths.live
        try paths.prepare()
        let db = try ProductionDatabase(url: paths.database)
        let adapter = ParakeetTranscriptionAdapter(database: db, paths: paths)
        if !(try await adapter.installed()) {
          print("PARAKEET_INSTALL: starting")
          try await adapter.install(onProgress: { _ in })
          print("PARAKEET_INSTALL: verified")
        }
        let started = Date()
        let output = try await adapter.transcribe(audioURL: url, modelID: ParakeetTranscriptionAdapter.modelID,
          locale: "en-GB", onProgress: { _ in })
        try JSONEncoder().encode(output).write(to: directory.appendingPathComponent("parakeet-transcript.json"))
        let file = try AVAudioFile(forReading: url)
        let segments = try CombinedTranscriptPreparation.prepare(primary: output, apple: nil,
          captions: [], captionSource: nil, sampleRate: Int(file.processingFormat.sampleRate), frameCount: Int(file.length))
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("parakeet-segments.json"))
        print("PARAKEET_RESULT: words=\(output.words.count), sentences=\(segments.count), audioSeconds=\(Double(file.length)/file.processingFormat.sampleRate), elapsedSeconds=\(Date().timeIntervalSince(started))")
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--failed-job-replay=") }) {
        let workspace = URL(fileURLWithPath: String(arg.dropFirst("--failed-job-replay=".count)))
        let whisper = try JSONDecoder().decode([TimedWord].self, from: Data(contentsOf: directory.appendingPathComponent("whisper-words-probe.json")))
        let apple = try JSONDecoder().decode(AudioTranscription.self, from: Data(contentsOf: directory.appendingPathComponent("apple-transcription-raw.json")))
        let captions = try WebVTTCaptionParser.parse(String(contentsOf: workspace.appendingPathComponent("Ahc8WG5FXCs.en-GB.vtt"), encoding: .utf8))
        let file = try AVAudioFile(forReading: workspace.appendingPathComponent("source.m4a"))
        let rate = Int(file.processingFormat.sampleRate)
        let count = Int(file.length)
        let segments = try CombinedTranscriptPreparation.prepare(whisper: whisper, variant: .large, apple: apple,
          captions: captions, captionSource: .creatorCaption, sampleRate: rate, frameCount: count)
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("failed-job-replay-segments.json"))
        let baselines = try segments.map { try JSONDecoder().decode(CaptionBaseline.self, from: Data($0.baselineJSON.utf8)) }
        print("REPLAY_MERGE: audioSeconds=\(Double(count)/Double(rate)), whisper=\(whisper.count), apple=\(apple.words.count), sentences=\(segments.count), excluded=\(baselines.flatMap { $0.reconciliation?.excludedWhisperWords ?? [] }.count)")
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--whisper-words-probe=") }) {
        let url = URL(fileURLWithPath: String(arg.dropFirst("--whisper-words-probe=".count)))
        let paths = BackendPaths.live
        let db = try ProductionDatabase(url: paths.database)
        let started = Date()
        let words = try await WhisperCaptionTranscriber(database: db, paths: paths).transcribe(audioURL: url, variant: .large)
        try JSONEncoder().encode(words).write(to: directory.appendingPathComponent("whisper-words-probe.json"))
        print("WHISPER_WORDS: count=\(words.count), sentences=\(NaturalSentenceSegmenter.segment(words).count), seconds=\(Date().timeIntervalSince(started))")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--import-cancel-previews") {
        let job = ProductionImportJob(id: UUID(), lessonID: UUID(), title: "The North Wind and the Sun",
          phase: .cancelled, runToken: UUID(), expectedGeneration: 1,
          error: .cancelled, createdAt: Date(), updatedAt: Date())
        try await write(ProductionImportJobBanner(job: job, showStatus: {}, cancel: {}, retry: {}).environment(store),
          size: CGSize(width: 1000, height: 100), name: "import-cancel-\(previewLanguage.rawValue)", directory: directory)
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--whisper-cancel-probe=") }) {
        let url = URL(fileURLWithPath: String(arg.dropFirst("--whisper-cancel-probe=".count)))
        let paths = BackendPaths.live
        let db = try ProductionDatabase(url: paths.database)
        let whisper = WhisperCaptionTranscriber(database: db, paths: paths)
        let tracker = TranscriptionProgressTracker()
        let id = UUID()
        let task = Task {
          try await whisper.transcribe(audioURL: url, variant: .large,
            onProgress: { _ in tracker.set(1, for: id) })
        }
        for _ in 0..<300 {
          if tracker.value(for: id) != nil { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard tracker.value(for: id) != nil else {
          task.cancel(); _ = await task.result
          throw CocoaError(.coderInvalidValue)
        }
        let started = Date()
        task.cancel()
        switch await task.result {
        case .success: throw CocoaError(.coderInvalidValue)
        case .failure(let error):
          guard error is CancellationError else { throw error }
          print("WHISPER_CANCEL: decoding started; CancellationError; seconds=\(Date().timeIntervalSince(started))")
        }
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--combined-reconcile-probe=") }) {
        let archive = try JSONDecoder().decode(CombinedTranscriptArchive.self,
          from: Data(contentsOf: directory.appendingPathComponent("combined-import-evidence.json")))
        guard let archiveApple = archive.apple else { throw CocoaError(.coderInvalidValue) }
        let captionURL = URL(fileURLWithPath: String(arg.dropFirst("--combined-reconcile-probe=".count)))
        let captions = try WebVTTCaptionParser.parse(String(contentsOf: captionURL, encoding: .utf8))
        let end = max(archive.whisperWords.map(\.end).max() ?? 0, archiveApple.words.map(\.end).max() ?? 0)
        let segments = try CombinedTranscriptPreparation.prepare(whisper: archive.whisperWords, variant: .large,
          apple: archiveApple, captions: captions, captionSource: .creatorCaption,
          sampleRate: 48000, frameCount: Int((end + 1) * 48000))
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("combined-three-source-segments.json"))
        let baselines = try segments.map { try JSONDecoder().decode(CaptionBaseline.self, from: Data($0.baselineJSON.utf8)) }
        print("THREE_SOURCE: captions=\(captions.count), whisper=\(archive.whisperWords.count), apple=\(archiveApple.words.count), sentences=\(segments.count), review=\(baselines.filter(\.wordTimingNeedsReview).count), corrections=\(baselines.flatMap { $0.reconciliation?.words ?? [] }.filter { $0.reviewReason == "caption_apple_correction" }.count)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--combined-model-previews") {
        let paths = BackendPaths.live
        let db = try ProductionDatabase(url: paths.database)
        let manager = WhisperModelManager(database: db, transcriber: WhisperCaptionTranscriber(database: db, paths: paths))
        await manager.refresh()
        let parakeet = ParakeetModelManager(adapter: ParakeetTranscriptionAdapter(database: db, paths: paths))
        await parakeet.refresh()
        store.preferences.activeTranscriptionModel = "large"
        try await write(RecordingModelsSettingsView().environment(store).environment(\.whisperModelManager, manager).environment(\.parakeetModelManager, parakeet),
          size: CGSize(width: 1400, height: 1550), name: "combined-models-\(previewLanguage.rawValue)", directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--combined-import-probe=") }) {
        let url = URL(fileURLWithPath: String(argument.dropFirst("--combined-import-probe=".count)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedImportProbe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BackendPaths(root: root)
        try paths.prepare()
        // Read the existing model through a symlink; probe results use an isolated database.
        try FileManager.default.removeItem(at: paths.packages)
        try FileManager.default.createSymbolicLink(at: paths.packages, withDestinationURL: BackendPaths.live.packages)
        let db = try ProductionDatabase(url: paths.database)
        let liveDB = try ProductionDatabase(url: BackendPaths.live.database)
        guard let release = try await liveDB.engineReleases(engineKey: WhisperModelCatalog.engineKey)
          .first(where: { $0.version == "large-v3" && $0.status == "installed" }) else { throw WhisperTranscriberError.modelNotInstalled }
        let id = try await db.registerEngineRelease(engineKey: WhisperModelCatalog.engineKey, version: release.version, capabilityJSON: "{}")
        try await db.setEngineInstallationStatus(releaseID: id, status: "installed", relativePath: release.relativePath)
        let importer = ProductionImportService(database: db, paths: paths, usesSpeechFallback: false,
          transcriber: WhisperCaptionTranscriber(database: db, paths: paths), audioTranscriber: AppleSpeechAnalyzerTranscriber())
        let job = try await importer.submit(.localAudio(url: url, securityScoped: false, titleOverride: "Combined probe"), whisperModel: "large")
        let started = Date()
        var ready: LibraryLessonSummary?
        for index in 0..<2400 {
          if let lesson = try await importer.librarySummaries().first(where: { $0.id == job.lessonID && $0.lifecycle == .ready }) { ready = lesson; break }
          if let status = try await importer.importJobs().first(where: { $0.id == job.id }) {
            if status.phase.isTerminal { throw status.error ?? ProductionImportError.cancelled }
            if index % 20 == 0 { print("COMBINED_PROGRESS: \(status.phase)") }
          }
          try await Task.sleep(for: .milliseconds(500))
        }
        guard let ready else { await importer.cancel(jobID: job.id); throw CocoaError(.coderInvalidValue) }
        let sentences = try await ProductionPracticeService(database: db, paths: paths).preparedSentences(lessonID: job.lessonID)
        try JSONEncoder().encode(sentences.map(\.baseline)).write(to: directory.appendingPathComponent("combined-import-baselines.json"))
        try sentences.map { $0.target.text }.joined(separator: "\n").write(to: directory.appendingPathComponent("combined-import-transcript.txt"), atomically: true, encoding: .utf8)
        let evidenceFiles = try FileManager.default.contentsOfDirectory(at: paths.root.appendingPathComponent("Media/Captions"), includingPropertiesForKeys: nil)
        if let evidence = evidenceFiles.first {
          try Data(contentsOf: evidence).write(to: directory.appendingPathComponent("combined-import-evidence.json"))
        }
        print("COMBINED_IMPORT: ready=\(ready.isPracticeReady), sentences=\(ready.preparedSentenceCount), review=\(ready.wordTimingReviewCount), tokens=\(sentences.flatMap(\.tokens).count), seconds=\(Date().timeIntervalSince(started))")
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--apple-import-probe=") }) {
        let url = URL(fileURLWithPath: String(argument.dropFirst("--apple-import-probe=".count)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleImportProbe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BackendPaths(root: root)
        try paths.prepare()
        let database = try ProductionDatabase(url: paths.database)
        let importer = ProductionImportService(database: database, paths: paths, usesSpeechFallback: false, audioTranscriber: AppleSpeechAnalyzerTranscriber())
        let job = try await importer.submit(.localAudio(url: url, securityScoped: false, titleOverride: "Apple import probe"), localeIdentifier: "en-GB")
        var ready: LibraryLessonSummary?
        for _ in 0..<1200 {
          if let lesson = try await importer.librarySummaries().first(where: { $0.id == job.lessonID && $0.lifecycle == .ready }) { ready = lesson; break }
          if let failed = try await importer.importJobs().first(where: { $0.id == job.id && $0.phase.isTerminal }) { throw failed.error ?? ProductionImportError.cancelled }
          try await Task.sleep(for: .milliseconds(250))
        }
        guard let ready else { await importer.cancel(jobID: job.id); throw CocoaError(.coderInvalidValue) }
        let sentences = try await ProductionPracticeService(database: database, paths: paths).preparedSentences(lessonID: job.lessonID)
        try JSONEncoder().encode(sentences.map(\.baseline)).write(to: directory.appendingPathComponent("apple-import-baselines.json"))
        try sentences.map { $0.target.text }.joined(separator: "\n").write(to: directory.appendingPathComponent("apple-import-transcript.txt"), atomically: true, encoding: .utf8)
        print("APPLE_IMPORT: ready=\(ready.isPracticeReady), sentences=\(ready.preparedSentenceCount), timingReviewSentences=\(ready.wordTimingReviewCount), tokens=\(sentences.flatMap(\.tokens).count)")
        print("PREVIEWS: \(directory.path)")
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--apple-transcribe=") }) {
        let url = URL(fileURLWithPath: String(argument.dropFirst("--apple-transcribe=".count)))
        if ProcessInfo.processInfo.arguments.contains("--apple-cancel-probe") {
          let task = Task { try await AppleSpeechAnalyzerTranscriber().transcribe(audioURL: url, localeIdentifier: "en-GB") }
          try await Task.sleep(for: .milliseconds(200))
          let cancelledAt = Date()
          task.cancel()
          switch await task.result {
          case .success: throw CocoaError(.coderInvalidValue)
          case .failure(let error):
            print("APPLE_CANCEL: \(error), elapsed \(Date().timeIntervalSince(cancelledAt)) seconds")
          }
          return
        }
        let started = Date()
        let result = try await AppleSpeechAnalyzerTranscriber().transcribe(audioURL: url, localeIdentifier: "en-GB")
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("apple-transcription-raw.json"))
        let file = try AVAudioFile(forReading: url)
        let segments = try AudioFirstPreparation.prepareSegments(
          transcript: result, sampleRate: Int(file.processingFormat.sampleRate), frameCount: Int(file.length))
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("apple-transcript-probe.json"))
        print("APPLE_TRANSCRIPT: \(result.words.count) tokens, \(segments.count) sentences, \(Date().timeIntervalSince(started)) seconds")
        print("PROVENANCE: \(result.provenance)")
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--apple-model-previews") {
        try await write(AppleSpeechTranscriptionSection().environment(store),
          size: CGSize(width: 650, height: 350), name: "apple-model-\(previewLanguage.rawValue)", directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--speech-previews") {
        for state in ["ready", "busy", "unavailable"] {
          try await write(
            SpeechPreparationSheet(
              isPreparing: state == "busy",
              error: state == "unavailable" ? EchoCopy("speech.preparation.unavailable") : nil,
              onContinue: {}, onClose: {}).environment(store),
            size: CGSize(width: 560, height: state == "unavailable" ? 430 : 380),
            name: "speech-\(state)-\(previewLanguage.rawValue)", directory: directory)
        }
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--ipa-previews") {
        let words = [
          LessonWord(id: "hello", text: "Hello", ipaUK: "həˈləʊ", ipaUS: "/həˈloʊ/"),
          LessonWord(id: "comma", text: ",", ipaUK: nil, ipaUS: nil),
          LessonWord(id: "world", text: "world", ipaUK: "/wɜːld/", ipaUS: "wɝld"),
          LessonWord(id: "bang", text: "!", ipaUK: nil, ipaUS: nil),
          LessonWord(id: "howard", text: "Howard", ipaUK: nil, ipaUS: "ˈhaʊɚd"),
          LessonWord(id: "question", text: "?", ipaUK: nil, ipaUS: nil),
        ]
        let sentence = LessonSentence(
          id: "ipa-preview", number: 1, text: "Hello, world! Howard?", translation: "",
          span: AudioSpan(start: 0, end: 3), words: words)
        for percent in [100, 160] {
          store.preferences.readingPercent = percent
          try await write(
            SentenceView(sentence: sentence, selectedWordID: .constant(nil), onWord: { _ in })
              .environment(store), size: CGSize(width: 1240, height: 330),
            name: "ipa-punctuation-\(percent)", directory: directory)
        }
        try await write(
          WordPronunciationView(sentence: sentence, wordID: "hello", onEditTiming: { _ in }, onClose: {})
            .environment(store), size: CGSize(width: 520, height: 526),
          name: "ipa-word-sheet", directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--modal-previews") {
        try await renderModals(store: store, directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--import-presentation-previews") {
        try await write(
          ImportProgressSheet(
            presentation: ImportPreparationFixtures.progress,
            onContinueBrowsing: {}, onCancelImport: {}).environment(store),
          size: ImportProgressSheet.size, name: "import-progress", directory: directory)
        try await write(
          ImportReadySheet(
            presentation: ImportPreparationFixtures.ready,
            onStartPracticing: {}, onBackToLibrary: {}).environment(store),
          size: ImportReadySheet.size, name: "import-ready", directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--settings-previews") {
        store.route = .settings
        for recording in [false, true] {
          for size in [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800),
            CGSize(width: 1440, height: 900), CGSize(width: 1800, height: 1060)] {
            try await write(AppRootView(settingsStartOnRecording: recording, usesPreviewLibrary: true).environment(store),
              size: size, name: "settings-page-\(recording ? "models" : "general")-\(Int(size.width))", directory: directory)
          }
        }
        for package in store.packages {
          try await write(ModelPackageCard(package: package, expanded: true,
            toggleDetails: {}, requestRemove: {}).environment(store).padding(24),
            size: CGSize(width: 620, height: 640), name: "settings-details-\(package.id.rawValue)", directory: directory)
        }
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--d00-previews") {
        for group in D00CatalogGroup.allCases {
          try await write(D00CatalogView(group: group).padding(32),
            size: CGSize(width: 1440, height: 900), name: "d00-\(group.rawValue)", directory: directory)
        }
        try await write(EchoUnsavedSheet(onKeepEditing: {}, onDiscard: {}, onSave: {}),
          size: CGSize(width: 620, height: 213), name: "d00-unsaved", directory: directory)
        if let lesson = store.selectedLesson {
          try await write(DeleteLessonSheet(lesson: lesson, store: store), size: CGSize(width: 700, height: 277),
            name: "d00-delete", directory: directory)
        }
        try await write(GeneralSettingsView().environment(store).padding(24),
          size: CGSize(width: 1000, height: 1000), name: "d00-general", directory: directory)
        for size in [CGSize(width: 752, height: 108), CGSize(width: 1032, height: 108)] {
          for phase: PracticePhase in [.listening, .paused, .idle] {
            store.practice.phase = phase
            store.practice.hasListened = phase != .listening
            try await write(PracticeTransportView(onOptions: {}, onReview: {}, compact: size.width < 900).environment(store),
              size: size, name: "d00-transport-\(Int(size.width))-\(phase)", directory: directory)
          }
        }
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--repeat-previews") {
        for expanded in [false, true] {
          for speed in PracticeOptions.speeds {
            store.preferences.speed = speed
            try await write(
              RepeatOptionsView(onClose: {}, initiallyExpanded: expanded).environment(store),
              size: CGSize(width: 420, height: expanded ? 480 : 380),
              name: "repeat-\(expanded ? "expanded" : "collapsed")-\(speed)", directory: directory)
          }
        }
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--reading-previews") {
        try await renderReading(store: store, directory: directory)
        print("PREVIEWS: \(directory.path)")
        return
      }
      for invalid in [false, true] {
        try await write(
          EchoTextField(
            label: "Tên bài", text: .constant(""), placeholder: "Tên hiển thị",
            helper: "Thông tin có thể chỉnh sau.",
            state: invalid ? .error("Nhập tên bài trước khi lưu.") : .idle
          ).padding(24),
          size: CGSize(width: 520, height: 132),
          name: invalid ? "input-error-focus" : "input-focus",
          directory: directory, focusFirstField: true)
      }
      try await write(
        EchoSearchField(placeholder: "Tìm trong bài…", text: .constant("")).padding(24),
        size: CGSize(width: 520, height: 80), name: "search-focus", directory: directory,
        focusFirstField: true)
      for section in ComponentGallerySection.allCases {
        try await write(
          ComponentGalleryView(section: section), size: CGSize(width: 1180, height: 1000),
          name: "components-\(section.id)", directory: directory)
      }
      for route in AppRoute.allCases {
        store.route = route
        if route == .shadowing {
          store.practice.playSentence()
          store.practice.interrupt()
          store.practice.phase = .listening
          store.practice.round = 3
          store.preferences.autoRecord = true
          if let span = store.selectedSentence?.span {
            store.practice.sourcePosition = span.start + span.duration * 0.3
          }
        }
        try await write(
          AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: 1280, height: 800),
          name: route.rawValue, directory: directory)
        try await write(
          AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: 1000, height: 680),
          name: "\(route.rawValue)-compact", directory: directory)
        for size in [CGSize(width: 1800, height: 1120), CGSize(width: 2560, height: 1080)] {
          try await write(
            AppRootView(usesPreviewLibrary: true).environment(store), size: size,
            name: "\(route.rawValue)-\(Int(size.width))", directory: directory)
        }
      }
      let lesson = store.selectedLesson!
      let sentence = store.selectedSentence!
      store.practice.phase = .paused
      store.route = .shadowing
      store.practice.phase = .recording
      try await write(
        AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: 1000, height: 680),
        name: "shadowing-capture-compact", directory: directory)
      store.practice.phase = .paused
      store.reviewTakeID = store.takes.last!.id
      try await write(
        AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: 1440, height: 960),
        name: "review-full", directory: directory)
      for size in [
        CGSize(width: 1000, height: 680), CGSize(width: 1280, height: 800),
        CGSize(width: 1800, height: 1120),
      ] {
        try await write(
          AppRootView(usesPreviewLibrary: true).environment(store), size: size,
          name: "review-\(Int(size.width))", directory: directory)
      }
      store.reviewTakeID = nil
      try await verifyWordSheet(store: store)
      try await write(
        SettingsView(recordingTab: true).environment(store), size: CGSize(width: 720, height: 960),
        name: "settings-models-content",
        directory: directory)
      for size in [
        CGSize(width: 680, height: 706), CGSize(width: 1000, height: 800),
        CGSize(width: 1800, height: 1120),
      ] {
        for recording in [false, true] {
          try await write(
            SettingsView(recordingTab: recording).environment(store), size: size,
            name: "settings-\(recording ? "models" : "general")-\(Int(size.width))",
            directory: directory)
        }
      }
      try await write(
        ImportSheet(store: store), size: CGSize(width: 700, height: 500), name: "import",
        directory: directory)
      try await write(
        DeleteLessonSheet(lesson: lesson, store: store), size: CGSize(width: 700, height: 277),
        name: "delete", directory: directory)
      try await write(
        RepeatOptionsView(onClose: {}).environment(store), size: CGSize(width: 420, height: 380),
        name: "repeat", directory: directory)
      try await write(
        MicrophonePreviewSheet().environment(store), size: CGSize(width: 680, height: 550),
        name: "microphone", directory: directory)
      try await write(
        WordPronunciationView(
          sentence: sentence, wordID: sentence.words[2].id, onEditTiming: { _ in }, onClose: {}
        ).environment(store), size: CGSize(width: 520, height: 526), name: "word",
        directory: directory)
      try await write(
        TimingEditorView(lesson: lesson, sentence: sentence, wordID: nil, onClose: {}).environment(
          store), size: CGSize(width: 720, height: 630), name: "timing", directory: directory)
      try await write(
        ReviewPanelView(take: store.takes.last!, onRecordAgain: {}, onPracticePhrase: { _ in })
          .environment(store), size: CGSize(width: 700, height: 880), name: "review",
        directory: directory)
      print("PREVIEWS: \(directory.path)")
    }

    private static func renderModals(store: EchoStore, directory: URL) async throws {
      guard let lesson = store.selectedLesson, let sentence = store.selectedSentence else {
        throw CocoaError(.coderValueNotFound)
      }
      let paths = BackendPaths(root: directory.appendingPathComponent(UUID().uuidString))
      try paths.prepare()
      defer { try? FileManager.default.removeItem(at: paths.root) }
      let database = try ProductionDatabase(url: paths.database)
      let library = ProductionLibraryModel(service: ProductionImportService(database: database, paths: paths))
      try await write(ProductionImportSheet(model: library, onSubmitted: { _ in }),
        size: CGSize(width: 620, height: 380), name: "modal-import-production", directory: directory)
      library.error = EchoCopy(ProductionImportError.duplicateIdentity.presentationDescription)
      try await write(ProductionImportSheet(model: library, onSubmitted: { _ in }),
        size: CGSize(width: 620, height: 380), name: "modal-import-error", directory: directory)
      try await write(ImportSheet(store: store), size: CGSize(width: 700, height: 500),
        name: "modal-import-preview", directory: directory)
      try await write(ImportProgressSheet(presentation: ImportPreparationFixtures.progress,
        onContinueBrowsing: {}, onCancelImport: {}), size: ImportProgressSheet.size,
        name: "modal-import-progress", directory: directory)
      try await write(ImportReadySheet(presentation: ImportPreparationFixtures.ready,
        onStartPracticing: {}, onBackToLibrary: {}), size: ImportReadySheet.size,
        name: "modal-import-ready", directory: directory)
      try await write(DeleteLessonSheet(lesson: lesson, store: store),
        size: CGSize(width: 700, height: 277), name: "modal-delete", directory: directory)
      for denied in [false, true] {
        try await write(MicrophonePreviewSheet(runtime: MicrophoneRuntimeActions(
          permissionDenied: denied, onListenOnly: {}, onRetry: {}, onOpenSettings: {})).environment(store),
          size: CGSize(width: 560, height: 400), name: "modal-microphone-\(denied)", directory: directory)
      }
      for expanded in [false, true] {
        try await write(RepeatOptionsView(onClose: {}, initiallyExpanded: expanded).environment(store),
          size: CGSize(width: 420, height: expanded ? 480 : 380),
          name: "modal-repeat-\(expanded)", directory: directory)
      }
      try await write(WordPronunciationView(sentence: sentence, wordID: sentence.words[2].id,
        onEditTiming: { _ in }, onClose: {}).environment(store),
        size: CGSize(width: 520, height: 526), name: "modal-word", directory: directory)
      try await write(TimingEditorView(lesson: lesson, sentence: sentence, onClose: {}).environment(store),
        size: CGSize(width: 720, height: 630), name: "modal-timing", directory: directory)
      var unaligned = sentence
      unaligned.words[2].span = nil
      try await write(WordPronunciationView(sentence: unaligned, wordID: unaligned.words[2].id,
        onEditTiming: { _ in }, onClose: {}).environment(store),
        size: CGSize(width: 520, height: 526), name: "modal-word-unaligned", directory: directory)
      try await write(TimingEditorView(lesson: lesson, sentence: unaligned,
        wordID: unaligned.words[2].id, onClose: {}).environment(store),
        size: CGSize(width: 720, height: 630), name: "modal-timing-unaligned", directory: directory)
      try await write(TimingEditorView(lesson: lesson, sentence: sentence, onClose: {},
        usesSimulatedWaveform: false, waveformError: "Fixture audio read failure").environment(store),
        size: CGSize(width: 720, height: 630), name: "modal-timing-error", directory: directory)
      try await write(EchoUnsavedSheet(onKeepEditing: {}, onDiscard: {}, onSave: {}),
        size: CGSize(width: 620, height: 213), name: "modal-unsaved", directory: directory)
      try await write(ReadingSizePopover(percent: .constant(100)),
        size: CGSize(width: 320, height: 254), name: "modal-reading", directory: directory)
    }

    private static func renderReading(store: EchoStore, directory: URL) async throws {
      store.route = .shadowing
      store.practice.playSentence()
      store.practice.interrupt()
      store.practice.phase = .listening
      store.practice.round = 4
      store.preferences.autoRecord = true
      if let span = store.selectedSentence?.words.first(where: { $0.text == "make" })?.span {
        store.practice.sourcePosition = (span.start + span.end) / 2
      }
      for (width, height, percent) in [
        (1800, 1120, 100), (1280, 860, 100), (1000, 680, 160), (1800, 1120, 160),
      ] {
        store.preferences.readingPercent = percent
        try await write(
          AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: width, height: height),
          name: "reading-\(width)-\(percent)", directory: directory)
      }
      for percent in [80, 100, 160] {
        try await write(
          ReadingSizePopover(percent: .constant(percent)), size: CGSize(width: 320, height: 254),
          name: "reading-popover-\(percent)", directory: directory)
      }
      for state in ReadingPreviewFixtures.feedbackStates {
        try await write(
          InlineTakeFeedbackRow(take: state.take, onReview: {}).padding(24).environment(store),
          size: CGSize(width: 1000, height: 140), name: "inline-\(state.name)", directory: directory
        )
      }
      store.practice.phase = .recording
      try await write(
        AppRootView(usesPreviewLibrary: true).environment(store), size: CGSize(width: 1800, height: 1120),
        name: "reading-recording", directory: directory)
      store.practice.discardPending()
    }
    private static func verifyWordSheet(store: EchoStore) async throws {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: WordSheetPlacementProbe().environment(store)
          .environment(\.locale, previewLanguage.locale))
      window.orderFront(nil)
      defer {
        for sheet in window.sheets { window.endSheet(sheet) }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
      try await Task.sleep(for: .milliseconds(600))
      guard let sheet = window.sheets.first else { throw CocoaError(.coderValueNotFound) }
      guard abs(sheet.frame.midX - window.frame.midX) < 1,
        abs(sheet.frame.midY - window.frame.midY) < 1,
        abs(sheet.frame.width - 520) < 1, abs(sheet.frame.height - 526) < 1
      else { throw CocoaError(.coderInvalidValue) }
      print(
        "WORD SHEET parent=\(window.frame) content=\(window.contentLayoutRect) sheet=\(sheet.frame)"
      )
    }
    private static func write<V: View>(
      _ view: V, size: CGSize, name: String, directory: URL,
      focusFirstField: Bool = false
    )
      async throws
    {
      let host = NSHostingView(
        rootView: view.frame(width: size.width, height: size.height).background(EchoTheme.canvas)
          .environment(\.locale, previewLanguage.locale)
          .preferredColorScheme(.dark))
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: focusFirstField ? [.titled] : [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.setContentSize(size)
      window.orderBack(nil)
      defer {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
      try await Task.sleep(for: .milliseconds(180))
      if focusFirstField {
        window.makeKeyAndOrderFront(nil)
        guard let field = firstTextField(in: host), window.makeFirstResponder(field)
        else { throw CocoaError(.coderValueNotFound) }
        try await Task.sleep(for: .milliseconds(180))
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor
        else { throw CocoaError(.coderInvalidValue) }
        print("FIELD FOCUS: \(name) · native field editor active")
      } else {
        window.makeFirstResponder(nil)
      }
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw CocoaError(.fileWriteUnknown)
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.isEditable { return field }
      for child in view.subviews {
        if let field = firstTextField(in: child) { return field }
      }
      return nil
    }
  }

  private struct WordSheetPlacementProbe: View {
    @Environment(EchoStore.self) private var store
    @State private var showing = false
    var body: some View {
      EchoTheme.canvas.onAppear { showing = true }
        .sheet(isPresented: $showing) {
          if let sentence = store.selectedSentence, let word = sentence.words.first {
            WordPronunciationView(
              sentence: sentence, wordID: word.id, onEditTiming: { _ in },
              onClose: { showing = false }
            ).environment(store)
          }
        }
    }
  }
#endif
