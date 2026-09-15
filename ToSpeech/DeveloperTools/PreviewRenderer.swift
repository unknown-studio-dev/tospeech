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
        "ToSpeechPreviews")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
      store.preferences.language = previewLanguage
      if ProcessInfo.processInfo.arguments.contains("--dictation-native-probe") {
        try await DictationNativeProbe.run()
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--dictation-previews") {
        let comparisonModel = DictationModel(storage: DictationMemoryStorage(), player: DictationPreviewAudio())
        try await comparisonModel.activate(DictationFixtures.sentences())
        for width in [760.0, 1032] {
          try await write(VStack(alignment: .leading, spacing: 20) {
            Text("Shadowing").font(EchoFont.body(size: 16, weight: .semibold))
            PracticeTransportView(onOptions: {}, onReview: {}, compact: width < 850)
            Text("Dictation").font(EchoFont.body(size: 16, weight: .semibold))
            PracticeTransportView(onOptions: {}, onReview: {}, compact: width < 850, dictationModel: comparisonModel)
          }.padding(20).environment(store), size: .init(width: width, height: 460),
            name: "shared-playback-\(Int(width))-\(previewLanguage.rawValue)", directory: directory)
        }
        comparisonModel.suspend()
        for width in [760.0, 1032] {
          for phase in ["ready", "writing", "paused", "result"] {
            let player = DictationPreviewAudio()
            let model = DictationModel(storage: DictationMemoryStorage(), player: player)
            try await model.activate(DictationFixtures.sentences())
            if phase != "ready" {
              model.play(); player.finish()
              model.edit("I never thought it would make such a")
              if phase == "result" { model.submit() }
              else if phase == "paused" { model.suspend() }
            }
            var dictationLesson = store.selectedLesson!
            dictationLesson.sentences = model.sentences.enumerated().map { $0.element.lessonSentence(number: $0.offset + 1) }
            try await write(DictationView(model: model,
              layout: .init(contentWidth: width, contentHeight: 752), lesson: dictationLesson)
              .environment(store), size: .init(width: width, height: 752),
              name: "dictation-\(phase)-\(Int(width))-\(previewLanguage.rawValue)", directory: directory)
            model.suspend(); await model.flush()
          }
        }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--recording-manager-previews") {
        let (fixture, _) = try AssessedReviewFixtures.make()
        var earlier = fixture
        earlier.id = UUID().uuidString
        earlier.number = max(1, fixture.number - 1)
        earlier.duration = 5.4
        earlier.createdAt = fixture.createdAt.addingTimeInterval(-3_600)
        var oldest = fixture
        oldest.id = UUID().uuidString
        oldest.number = max(1, fixture.number - 2)
        oldest.duration = 7.8
        oldest.createdAt = fixture.createdAt.addingTimeInterval(-86_400)
        let recordings = [fixture, earlier, oldest]
        let selected = Set(recordings.prefix(2).map(\.id))
        let byteCounts = Dictionary(uniqueKeysWithValues: recordings.enumerated().compactMap {
          index, take in UUID(uuidString: take.id).map { ($0, Int64((index + 2) * 620_000)) }
        })
        for (name, confirming) in [("selection", false), ("confirmation", true)] {
          try await write(RecordingManagerSheet(
            recordings: recordings,
            initialSelection: selected,
            initiallyConfirming: confirming,
            loadByteCounts: { byteCounts },
            delete: { _ in 0 },
            close: {}
          ).environment(store), size: .init(width: 640, height: 600),
            name: "recording-manager-\(name)-\(previewLanguage.rawValue)",
            directory: directory, settleMilliseconds: 350)
        }
        print("RECORDING_MANAGER_PREVIEWS: \(directory.path)")
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--recording-trim-probe=") }) {
        try await RecordingEnhancementProbe.trim(
          url: URL(fileURLWithPath: String(argument.dropFirst("--recording-trim-probe=".count))), directory: directory)
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--recording-enhancement-probe=") }) {
        try await RecordingEnhancementProbe.run(
          url: URL(fileURLWithPath: String(argument.dropFirst("--recording-enhancement-probe=".count))), directory: directory)
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--saved-uk-retry-root=") }) {
        try await PronunciationProbe.retrySavedUKJob(
          root: URL(fileURLWithPath: String(argument.dropFirst("--saved-uk-retry-root=".count))), outputDirectory: directory)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--signal-previews") {
        let (take, job) = try AssessedReviewFixtures.make()
        var other = take; other.id = UUID().uuidString; other.number = take.number - 1; other.duration = 6
        var assets: [ReviewAudioAsset] = []
        for (id, duration) in [("source", 4.0), (take.id, 4.8), (other.id, 6.0)] {
          let url = directory.appendingPathComponent("signal-fixture-\(id).caf")
          let frames = Int(duration * 16_000)
          let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
          buffer.frameLength = AVAudioFrameCount(frames)
          var phase = 0.0
          for i in 0..<frames {
            let t = Double(i) / 16_000
            phase += 2 * .pi * (150 + 25 * sin(t * 4)) / 16_000
            let level = t < 0.25 || (t > 1.8 && t < 2.2) ? 0 : 0.3 * pow(abs(sin(t * 7)), 2)
            buffer.floatChannelData![0][i] = Float(level * sin(phase))
          }
          do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
          let asset = ReviewAudioAsset(id: id, url: url, sampleRate: 16_000, startFrame: 0, endFrame: frames)
          assets.append(asset)
          _ = try await ReviewSignalAnalyzer.shared.waveform(asset)
          _ = try await ReviewSignalAnalyzer.shared.contour(asset)
        }
        defer { for asset in assets { try? FileManager.default.removeItem(at: asset.url) } }
        let runtime = ReviewRuntimePresentation(history: [other, take], selectedTakeID: take.id,
          onSelectTake: { _ in }, onPreviewOriginal: {}, onPreviewTake: {}, onCompare: {},
          assessmentUnavailableText: nil, onCompareTogether: {}, sourceAsset: assets[0], takeAssets: Array(assets.dropFirst()))
        for mode in ReviewSignalMode.allCases {
          for width in [360.0, 760, 1032] {
            try await write(VStack(alignment: .leading, spacing: 8) {
              Text("DESIGN FIXTURE · DỮ LIỆU MINH HOẠ").font(.system(size: 11)).foregroundStyle(EchoTheme.secondaryText)
              ReviewSignalComparisonView(take: take, runtime: runtime, evidence: nil, onPreparePlayback: {}, initialMode: mode)
            }.padding(12).environment(store), size: .init(width: width, height: width < 400 ? 570 : 430),
              name: "signal-\(mode.rawValue)-\(Int(width))-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        for width in [760.0, 1032, 1600] {
          try await write(ProductionTakeReviewView(layout: .init(contentWidth: width, contentHeight: 1100), take: take,
            runtime: runtime, onBack: {}, onRecordAgain: {}, source: {
              VideoPreviewView(lesson: store.selectedLesson!, onEdit: {})
            }, fixtureHistory: [job]).environment(store), size: .init(width: width, height: 1100),
            name: "signal-review-\(Int(width))-\(previewLanguage.rawValue)", directory: directory)
        }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--review-playback-previews") {
        let (take, job) = try AssessedReviewFixtures.make()
        store.preferences.productionAssessmentEngine = .buddy
        let url = directory.appendingPathComponent("review-playback-silence.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288_000)!
        buffer.frameLength = 288_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 288_000)
        do {
          let audio = try AVAudioFile(forWriting: url, settings: format.settings)
          try audio.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let player = ProductionAudioPlayer()
        defer { player.stop() }
        try player.playTogether(sourceURL: url, sourceFrames: 0..<192_000,
          takeURL: url, takeFrames: 0..<288_000)
        // Freeze on “thought”, which also contains red/yellow assessment IPA.
        for _ in 0..<150 {
          if player.rangeElapsed >= 1.0 { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        player.pause()
        for size in [CGSize(width: 760, height: 632), CGSize(width: 1032, height: 752), CGSize(width: 1600, height: 960)] {
          try await write(ProductionTakeReviewView(
            layout: .init(contentWidth: size.width, contentHeight: size.height), take: take,
            runtime: .init(history: [take], selectedTakeID: take.id, onSelectTake: { _ in },
              onPreviewOriginal: {}, onPreviewTake: {}, onCompare: {}, assessmentUnavailableText: nil,
              player: player, sourceAudioURL: url, onCompareTogether: {}),
            onBack: {}, onRecordAgain: {}, source: {
              VideoPreviewView(lesson: store.selectedLesson!, onEdit: {})
                .overlay(alignment: .topLeading) {
                  Text("PLAYBACK FIXTURE · DỮ LIỆU MINH HOẠ").font(.system(size: 11)).padding(8).background(EchoTheme.surface)
                }
            }, fixtureHistory: [job]).environment(store),
            size: size, name: "review-playback-\(Int(size.width))-\(previewLanguage.rawValue)", directory: directory)
        }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--uk-coach-previews") {
        for symbol in ["θ", "eə", "ʔ", "l̩", "ɐ"] {
          try await write(UKSoundCoachView(symbol: symbol, onSpeak: { _ in }).padding(16).environment(store),
            size: CGSize(width: 400, height: 420), name: "uk-coach-\(symbol)-\(previewLanguage.rawValue)", directory: directory)
        }
        for width in [340, 432, 700] {
          try await write(UKSoundLibraryView(selectedSymbol: .constant("θ"), onSpeak: { _ in },
            onSpeakSound: { _ in }, playingSymbol: "θ").padding(16).environment(store),
            size: CGSize(width: width, height: 680), name: "uk-coach-library-\(width)-\(previewLanguage.rawValue)", directory: directory)
        }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--assessment-error-previews") {
        let (take, _) = try AssessedReviewFixtures.make()
        for width in [400, 1032] {
          try await write(EchoPanel {
            InlineTakeFeedbackRow(take: take, onReview: {}, runtime: .init(
              actionsBlocked: false, onCheckMicrophone: {}, onCompare: {}, onRetry: {}, onReview: {},
              matchingState: .failed, matchingMessage: "assessment.uk.error.word_phones", errorWord: "pronunciation"))
          }.environment(store), size: CGSize(width: width, height: 300),
            name: "assessment-error-\(width)-\(previewLanguage.rawValue)", directory: directory)
        }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--review-drawer-previews") {
        let (take, job) = try AssessedReviewFixtures.make()
        store.preferences.productionAssessmentEngine = .buddy
        let runtime = ReviewRuntimePresentation(
          history: [take], selectedTakeID: take.id, onSelectTake: { _ in },
          onPreviewOriginal: {}, onPreviewTake: {}, onCompare: {},
          assessmentUnavailableText: nil)
        let states: [(String, TakeReviewPage, DeliveryDimension)] = [
          ("overview", .overview, .intonation), ("sound", .phone, .intonation),
          ("delivery", .delivery, .stress), ("signals", .signals, .intonation),
          ("content", .content, .intonation), ("details", .details, .intonation),
          ("library", .guide, .intonation)
        ]
        for (name, page, dimension) in states {
          try await write(ProductionTakeReviewView(
            layout: .init(contentWidth: 432, contentHeight: 800), take: take,
            runtime: runtime, onBack: {}, onRecordAgain: {}, source: { Color.clear },
            fixtureHistory: [job], initialPage: page, initialDimension: dimension,
            presentation: .drawer).environment(store),
            size: .init(width: 432, height: 800),
            name: "review-drawer-\(name)-\(previewLanguage.rawValue)", directory: directory,
            settleMilliseconds: 450)
        }
        print("REVIEW_DRAWER_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--integrated-review-previews") {
        let (take, original) = try AssessedReviewFixtures.make()
        store.preferences.productionAssessmentEngine = .buddy
        let variants: [(String, TakeReviewPage, PronunciationJob.Status, Int)] = [
          ("overview", .overview, .complete, 100), ("phone", .phone, .complete, 100), ("guide", .guide, .complete, 100),
          ("delivery", .delivery, .complete, 100), ("queued", .overview, .queued, 100),
          ("failed", .overview, .failed, 100), ("large-type", .overview, .complete, 160)]
        for (name, page, status, readingPercent) in variants {
          store.preferences.readingPercent = readingPercent
          var job = original
          job.status = status
          if status != .complete { job.result = nil }
          if status == .failed { job.error = "assessment.error.model_missing" }
          for size in [CGSize(width: 760, height: 632), CGSize(width: 1032, height: 752), CGSize(width: 1600, height: 960)] {
            try await write(ProductionTakeReviewView(
              layout: .init(contentWidth: size.width, contentHeight: size.height), take: take,
              runtime: .init(history: [take], selectedTakeID: take.id, onSelectTake: { _ in },
                onPreviewOriginal: {}, onPreviewTake: {}, onCompare: {}, assessmentUnavailableText: nil),
              onBack: {}, onRecordAgain: {}, source: {
                VideoPreviewView(lesson: store.selectedLesson!, onEdit: {})
                  .overlay(alignment: .topLeading) {
                    Text("DESIGN FIXTURE · DỮ LIỆU MINH HOẠ").font(.system(size: 11)).padding(8).background(EchoTheme.surface)
                  }
              }, fixtureHistory: [job], initialPage: page).environment(store),
              size: size, name: "integrated-review-\(name)-\(Int(size.width))-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        print("INTEGRATED_REVIEW_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--uk-reference-previews") {
        let job = try JSONDecoder().decode(PronunciationJob.self,
          from: Data(contentsOf: directory.appendingPathComponent("pronunciation-probe-result.json")))
        guard let evidence = job.result, evidence.ukReference != nil else { throw BuddyError.invalidOutput }
        let sourceDuration = Double(job.target.endFrame-job.target.startFrame)/Double(job.target.sampleRate)
        let sentence = LessonSentence(id: job.target.segmentRevisionID.uuidString, number: 1,
          text: job.target.text, translation: "", span: .init(start: 0, end: sourceDuration),
          words: evidence.words.map { word in
            .init(id: word.id, text: word.target.text, ipaUK: word.referenceIPA, ipaUS: nil,
              span: .init(start: word.target.sourceStart ?? 0, end: word.target.sourceEnd ?? sourceDuration))
          })
        let take = PracticeTake(id: job.takeID.uuidString, lessonID: job.target.lessonID.uuidString,
          sentenceID: sentence.id, number: 1, createdAt: job.createdAt, duration: evidence.duration,
          outcome: .complete, sourceSnapshot: sentence, sourceSpeed: 1, scope: .sentence, wordIDs: [], assessments: [])
        store.preferences.productionAssessmentEngine = .ukReference
        for (name, page, dimension) in [("overview", TakeReviewPage.overview, DeliveryDimension.intonation),
          ("phone", .phone, .intonation), ("guide", .guide, .intonation),
          ("stress", .delivery, .stress), ("intonation", .delivery, .intonation), ("rhythm", .delivery, .rhythm), ("linking", .delivery, .linking)] {
          for size in [CGSize(width: 1032, height: 752), CGSize(width: 760, height: 632)] {
            try await write(ProductionTakeReviewView(
              layout: .init(contentWidth: size.width, contentHeight: size.height), take: take,
              runtime: .init(history: [take], selectedTakeID: take.id, onSelectTake: { _ in },
                onPreviewOriginal: {}, onPreviewTake: {}, onCompare: {}, assessmentUnavailableText: nil),
              onBack: {}, onRecordAgain: {}, source: {
                VideoPreviewView(lesson: store.selectedLesson!, onEdit: {})
                  .overlay(alignment: .topLeading) {
                    Text("LOCAL MODEL OUTPUT · TEST AUDIO").font(.system(size: 11)).padding(8).background(EchoTheme.surface)
                  }
              }, fixtureHistory: [job], initialPage: page, initialDimension: dimension).environment(store),
              size: size, name: "uk-reference-\(name)-\(Int(size.width))-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        if let xeus = evidence.phoneticXeus, let reference = xeus.reference {
          for symbol in ["əʊ", "eɪ", "uː", "ɛə", "ə"] {
            let candidates = xeus.words.flatMap(\.phones).filter { $0.expected == symbol }
            let selected = symbol == "ə" ? candidates.first { phone in
              reference.groups.first { $0.id == phone.diagnostic?.groupID }?.shared == true
            } : candidates.first
            if let phone = selected, let detail = phone.diagnostic,
              let group = reference.groups.first(where: { $0.id == detail.groupID }) {
              for width in [360.0, 432.0] {
                try await write(VStack(alignment: .leading, spacing: 16) {
                  Text(verbatim: "UK /\(symbol)/").font(EchoFont.heading(size: 28))
                  XeusReferenceDetailView(detail: detail, group: group, policy: xeus.policy, metricsExpanded: .constant(width == 432))
                  Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                  .background(EchoTheme.surface), size: .init(width: width, height: width == 432 ? 1000 : 580),
                  name: "xeus-diagnostic-\(symbol)-\(Int(width))-\(previewLanguage.rawValue)", directory: directory)
              }
            }
          }
        }
        print("UK_REFERENCE_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--pronunciation-install-probe") {
        let paths = BackendPaths(root: directory.appendingPathComponent("install-probe-\(UUID())"))
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let package = BuddyModelPackage(paths: paths)
        try await package.install()
        let installed = try await package.validate()
        print("PRONUNCIATION_INSTALL: verified \(installed.path)")
        try await package.remove()
        guard await !package.installed() else { throw BuddyError.busy }
        print("PRONUNCIATION_INSTALL: removal verified")
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pronunciation-probe=") }) {
        try await PronunciationProbe.run(audioURL: URL(fileURLWithPath: String(argument.dropFirst("--pronunciation-probe=".count))), outputDirectory: directory)
        return
      }
      if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--matching-probe=") }) {
        try await ContentMatchingProbe.run(audioURL: URL(fileURLWithPath: String(argument.dropFirst("--matching-probe=".count))),
          outputDirectory: directory)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--pronunciation-previews") {
        let stored = try JSONDecoder().decode(PronunciationJob.self, from: Data(contentsOf: directory.appendingPathComponent("pronunciation-probe-result.json")))
        store.preferences.productionAssessmentEngine = .buddy
        for status in [PronunciationJob.Status.complete, .queued, .failed, .unrecognized] {
          var job = stored
          job.status = status
          if status != .complete { job.result = nil }
          if status == .failed { job.error = "assessment.error.model_missing" }
          if status == .unrecognized { job.error = "assessment.error.no_speech" }
          for width in [400, 560] {
            try await write(EchoPanel {
              ScrollView {
                PronunciationReviewView(history: [job], onRetry: { _ in }, onRecover: {}, onAssess: {}, onReplay: { _, _ in })
              }
            }.environment(store).environment(\.locale, store.preferences.language.locale), size: CGSize(width: width, height: 750),
              name: "pronunciation-\(status.rawValue)-\(width)-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        print("PRONUNCIATION_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--matching-previews") {
        for status in [ContentMatchingJob.Status.complete, .queued, .running, .failed, .unrecognized] {
          let job = try ContentMatchingFixtures.job(status: status)
          for width in [400, 560] {
            try await write(EchoPanel {
              ScrollView {
                ContentMatchingReviewView(history: [job], onRetry: { _ in }, onRecover: {})
              }
            }.environment(store), size: CGSize(width: width, height: 650),
              name: "matching-\(status.rawValue)-\(width)-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        print("MATCHING_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--modal-overflow-previews") {
        try await verifyModalOverflow(store: store, directory: directory)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--word-pronunciation-previews"),
        let source = store.selectedSentence {
        for (name, text, uk, us) in [
          ("is", "is", "ɪz", "ɪz"),
          ("long", "pronunciation", "prəˌnʌnsiˈeɪʃən", "prəˌnʌnsiˈeɪʃən"),
          ("missing", "is", "", "ɪz"),
          ("missing-voice", "shadowing", "", "ˈʃædoʊɪŋ"),
          ("punctuation", ".", "", "")
        ] {
          var sentence = source
          let word = LessonWord(id: "word-preview", text: text, ipaUK: uk.isEmpty ? nil : uk,
            ipaUS: us.isEmpty ? nil : us, span: source.words.first?.span)
          sentence.words = [word]
          try await write(WordPronunciationView(sentence: sentence, wordID: word.id,
            onEditTiming: { _ in }, onClose: {}, onPreviewReference: { _, _ in },
            usesPreviewReferenceAudio: false, referenceUsesAppleVoice: true,
            referenceErrorKey: name == "missing-voice" ? "word.reference.missing.uk" : nil
          ).environment(store),
            size: CGSize(width: 520, height: name == "missing-voice" ? 640 : 526),
            name: "word-top-ipa-\(name)-\(previewLanguage.rawValue)", directory: directory)
        }
        print("PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--linking-previews") {
        let words = [("I", "aɪ"), ("never", "ˈnevə"), ("thought", "θɔːt"), ("it", "ɪt"),
          ("would", "wʊd"), ("make", "meɪk"), ("such", "sʌtʃ"), ("a", "ə"), ("difference.", "ˈdɪfərəns")]
        let sentence = LessonSentence(id: "linking-preview", number: 18,
          text: words.map { $0.0 }.joined(separator: " "),
          translation: "Tôi chưa bao giờ nghĩ rằng nó lại có thể tạo ra khác biệt lớn đến vậy.",
          span: AudioSpan(start: 0, end: 9), words: words.enumerated().map { i, item in
            LessonWord(id: "word-\(i)", text: item.0, ipaUK: item.1, ipaUS: item.1,
              span: AudioSpan(start: Double(i), end: Double(i + 1)))
          })
        for (width, percent, enabled) in [(1032, 100, true), (752, 160, true), (1032, 100, false)] {
          store.preferences.showLinking = enabled
          store.preferences.readingPercent = percent
          try await write(SentenceView(sentence: sentence, selectedWordID: .constant(nil),
            onReview: {},
            runtime: SentenceRuntimePresentation(playingWordID: "word-2", interactionDisabled: false,
              hasCurrentTake: true, takeCount: 4, sentenceCount: 42), onPreviewLink: { _, _ in }, onWord: { _ in })
            .environment(store), size: CGSize(width: width, height: percent == 160 ? 530 : 290),
            name: "linking-sentence-\(width)-\(percent)-\(enabled)-\(previewLanguage.rawValue)", directory: directory)
        }
        if let hint = LinkingSuggestions.suggestions(in: sentence, accent: .uk).first {
          for available in [true, false] {
            try await write(LinkingSuggestionPopover(suggestion: hint, canPlay: available,
              timingNeedsReview: false, speed: .constant(0.75), onPlay: {}, onClose: {}),
              size: CGSize(width: 360, height: available ? 350 : 410),
              name: "linking-popover-\(available)-\(previewLanguage.rawValue)", directory: directory)
          }
        }
        print("LINKING_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--onboarding-previews") {
        // Step 1 twice: before any native language is chosen, then with Vietnamese picked.
        var fresh = store.preferences
        fresh.hasCompletedOnboarding = false
        for (name, step, language) in [("unchosen", 0, nil), ("chosen", 0, "vi"), ("none", 0, "none"), ("level", 1, "vi"), ("setup", 2, "vi")] as [(String, Int, String?)] {
          let snapshot = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
          snapshot.preferences = fresh
          if let language { snapshot.preferences.selectTranslationLanguage(language) }
          if step == 1 { LearnerLevel.beginning.apply(to: &snapshot.preferences) }
          try await write(OnboardingView(parakeetModels: nil, pronunciationModels: nil, storageReady: true, initialStep: step)
            .environment(snapshot), size: CGSize(width: 1180, height: 860),
            name: "onboarding-\(step + 1)-\(name)-\(previewLanguage.rawValue)", directory: directory, settleMilliseconds: 900)
        }
        print("ONBOARDING_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--pace-previews") {
        // Realistic timing: function words crushed, content words stretched, a pause at the comma.
        let words: [(String, String, Double, Double)] = [
          ("The", "ðə", 0.00, 0.12), ("country", "ˈkʌntɹi", 0.12, 0.55), ("mouse", "maʊs", 0.55, 0.92),
          ("was", "wəz", 0.92, 1.02), ("easily", "ˈiːzɪli", 1.02, 1.50), ("persuaded,", "pəˈsweɪdɪd", 1.50, 2.30),
          ("and", "ənd", 2.72, 2.80), ("returned", "ɹɪˈtɜːnd", 2.80, 3.40), ("to", "tə", 3.40, 3.48),
          ("town", "taʊn", 3.48, 3.98), ("with", "wɪð", 3.98, 4.12), ("his", "hɪz", 4.12, 4.24),
          ("friend.", "fɹend", 4.24, 5.10),
        ]
        let sentence = LessonSentence(id: "pace-preview", number: 13,
          text: words.map { $0.0 }.joined(separator: " "),
          translation: "Con chuột đồng quê dễ dàng bị thuyết phục và trở về thị trấn cùng với người bạn của mình.",
          span: AudioSpan(start: 0, end: 5.2), words: words.enumerated().map { i, item in
            LessonWord(id: "word-\(i)", text: item.0, ipaUK: item.1, ipaUS: item.1,
              span: AudioSpan(start: item.2, end: item.3))
          })
        store.preferences.showLinking = false
        for (width, percent, enabled) in [(1032, 100, true), (752, 160, true), (1032, 100, false)] {
          store.preferences.showPace = enabled
          store.preferences.readingPercent = percent
          try await write(SentenceView(sentence: sentence, selectedWordID: .constant(nil),
            onReview: {},
            runtime: SentenceRuntimePresentation(playingWordID: nil, interactionDisabled: false,
              hasCurrentTake: true, takeCount: 4, sentenceCount: 64), onPreviewLink: { _, _ in }, onWord: { _ in })
            .environment(store), size: CGSize(width: width, height: percent == 160 ? 560 : 320),
            name: "pace-sentence-\(width)-\(percent)-\(enabled)-\(previewLanguage.rawValue)", directory: directory)
        }
        print("PACE_PREVIEWS: \(directory.path)")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--level-source-audio") {
        // Reports every stored source file's loudness; --apply-levelling re-encodes
        // the ones off target (lossy, one way) and updates their media rows.
        let paths = BackendPaths.live
        let database = try ProductionDatabase(url: paths.database)
        let service = ProductionImportService(database: database, paths: paths, usesSpeechFallback: false)
        let apply = ProcessInfo.processInfo.arguments.contains("--apply-levelling")
        for report in try await service.levelStoredSourceAudio(apply: apply) {
          let measured = report.measuredLUFS.map { String(format: "%.1f LUFS", $0) } ?? "unmeasurable"
          print("SOURCE_LEVEL: \(report.relativePath) measured=\(measured) gain=\(String(format: "%+.1f dB", report.gainDB)) applied=\(report.applied)")
        }
        return
      }
      if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--align-lesson=") }) {
        guard let lessonID = UUID(uuidString: String(arg.dropFirst("--align-lesson=".count))) else { throw CocoaError(.coderInvalidValue) }
        let paths = BackendPaths.live
        let database = try ProductionDatabase(url: paths.database)
        let service = ProductionPracticeService(database: database, paths: paths)
        let before = try await service.preparedSentences(lessonID: lessonID)
        guard ProcessInfo.processInfo.arguments.contains("--apply-alignment") else {
          print("ALIGNMENT_AUDIT: sentences=\(before.count), manual=\(before.filter(\.hasManualTiming).count); no changes")
          return
        }
        let takesBefore = try await service.takes(lessonID: lessonID)
        let repair = AlignedWordTimingPreparer(service: service, aligner: CoreMLWordAligner())
        let changed = try await repair.prepare(sentences: before, localeIdentifier: "en-GB")
        let after = try await service.preparedSentences(lessonID: lessonID)
        let takesAfter = try await service.takes(lessonID: lessonID)
        guard takesBefore == takesAfter else { throw CocoaError(.coderInvalidValue) }
        let revised = zip(before, after).filter { $0.id != $1.id }.count
        let aligned = after.reduce(0) { $0 + ($1.baseline.alignment?.alignedWordIDs.count ?? 0) }
        print("ALIGNMENT_APPLIED: changed=\(changed), revisions=\(revised), alignedWords=\(aligned), takesPreserved=\(takesAfter.count)")
        return
      }
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
          transcriptionAdapters: TranscriptionAdapterRegistry([adapter]), wordAligner: CoreMLWordAligner())
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
        guard !sentences.isEmpty, hasSource, sentences.allSatisfy({ $0.baseline.alignment != nil }) else { throw CocoaError(.coderInvalidValue) }
        print("PARAKEET_IMPORT: ready; sentences=\(sentences.count); provenance=parakeet; alignment=ctc; noApple=true; elapsedSeconds=\(Date().timeIntervalSince(started)); root=\(root.path)")
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
      if ProcessInfo.processInfo.arguments.contains("--import-cancel-previews") {
        let job = ProductionImportJob(id: UUID(), lessonID: UUID(), title: "The North Wind and the Sun",
          phase: .cancelled, runToken: UUID(), expectedGeneration: 1,
          error: .cancelled, createdAt: Date(), updatedAt: Date())
        try await write(ProductionImportJobBanner(job: job, showStatus: {}, cancel: {}, retry: {}).environment(store),
          size: CGSize(width: 1000, height: 100), name: "import-cancel-\(previewLanguage.rawValue)", directory: directory)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--combined-model-previews") {
        let paths = BackendPaths.live
        let db = try ProductionDatabase(url: paths.database)
        let parakeet = ParakeetModelManager(adapter: ParakeetTranscriptionAdapter(database: db, paths: paths))
        await parakeet.refresh()
        try await write(RecordingModelsSettingsView().environment(store).environment(\.parakeetModelManager, parakeet),
          size: CGSize(width: 1400, height: 1550), name: "combined-models-\(previewLanguage.rawValue)", directory: directory)
        print("PREVIEWS: \(directory.path)")
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
              error: state == "unavailable" ? EchoCopy("alignment.error.model_unavailable") : nil,
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
        let paths = BackendPaths(root: directory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let database = try ProductionDatabase(url: paths.database)
        let library = ProductionLibraryModel(service: ProductionImportService(database: database, paths: paths))
        try await write(ProductionImportSheet(model: library, onSubmitted: { _ in }).environment(store),
          size: CGSize(width: 620, height: 380), name: "import-url-\(previewLanguage.rawValue)", directory: directory)
        try await write(
          ImportProgressSheet(
            presentation: ImportPreparationFixtures.progress,
            onContinueBrowsing: {}, onCancelImport: {}).environment(store),
          size: ImportProgressSheet.size, name: "import-progress-\(previewLanguage.rawValue)", directory: directory)
        try await write(
          ImportReadySheet(
            presentation: ImportPreparationFixtures.ready,
            onStartPracticing: {}, onBackToLibrary: {}).environment(store),
          size: ImportReadySheet.size, name: "import-ready-\(previewLanguage.rawValue)", directory: directory)
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
      try await write(ProductionImportSheet(model: library, onSubmitted: { _ in }).environment(store),
        size: CGSize(width: 620, height: 380), name: "modal-import-production", directory: directory)
      library.error = EchoCopy(ProductionImportError.duplicateIdentity.presentationDescription)
      try await write(ProductionImportSheet(model: library, onSubmitted: { _ in }).environment(store),
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
          permissionDenied: denied, permissionGranted: !denied,
          onListenOnly: {}, onRetry: {}, onOpenSettings: {})).environment(store),
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
    private static func verifyModalOverflow(store: EchoStore, directory: URL) async throws {
      let state = ModalOverflowProbeState()
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ModalOverflowProbe(state: state).environment(store)
        .environment(\.locale, previewLanguage.locale))
      window.center()
      window.orderFront(nil)
      defer {
        for sheet in window.sheets { window.endSheet(sheet) }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
      for stage in 0...7 {
        state.stage = stage
        if stage == 3 { window.setContentSize(CGSize(width: 1000, height: 600)) }
        try await Task.sleep(for: .milliseconds(850))
        guard let sheet = window.sheets.first, let host = sheet.contentView else {
          throw CocoaError(.coderValueNotFound)
        }
        host.layoutSubtreeIfNeeded()
        print("MODAL_OVERFLOW stage=\(stage) parent=\(window.contentLayoutRect.size) sheet=\(sheet.frame.size) host=\(host.bounds.size)")
        let expectedWidth: CGFloat = stage == 0 ? 520 : stage < 4 ? 720 : stage < 6 ? 700 : 420
        guard abs(host.bounds.width - expectedWidth) < 1,
          host.bounds.height <= window.contentLayoutRect.height - 48 else {
          throw CocoaError(.coderInvalidValue)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
          throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
          throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent("modal-overflow-\(stage).png"))
        if stage == 3 {
          guard let scroll = verticalScrollView(in: host), let document = scroll.documentView else {
            throw CocoaError(.coderValueNotFound)
          }
          let before = scroll.documentVisibleRect.origin.y
          document.scroll(CGPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
          scroll.reflectScrolledClipView(scroll.contentView)
          try await Task.sleep(for: .milliseconds(100))
          guard scroll.documentVisibleRect.origin.y > before else { throw CocoaError(.coderInvalidValue) }
          host.cacheDisplay(in: host.bounds, to: bitmap)
          guard let bottom = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
          }
          try bottom.write(to: directory.appendingPathComponent("modal-overflow-3-scrolled.png"))
          print("MODAL_SCROLL before=\(before) after=\(scroll.documentVisibleRect.origin.y)")
        }
      }
      print("MODAL_PREVIEWS: \(directory.path)")
    }

    private static func verticalScrollView(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView,
        let document = scroll.documentView, document.bounds.height > scroll.contentSize.height + 1 {
        return scroll
      }
      for child in view.subviews {
        if let scroll = verticalScrollView(in: child) { return scroll }
      }
      return nil
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
      focusFirstField: Bool = false, settleMilliseconds: Int = 180
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
      try await Task.sleep(for: .milliseconds(settleMilliseconds))
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

  @MainActor @Observable private final class ModalOverflowProbeState {
    var stage = 0
  }

  private struct ModalOverflowProbe: View {
    @Environment(EchoStore.self) private var store
    let state: ModalOverflowProbeState
    @State private var showing = false
    var body: some View {
      EchoTheme.canvas.onAppear { showing = true }
        .sheet(isPresented: $showing) {
          Group {
            if let lesson = store.selectedLesson, let sentence = store.selectedSentence,
              let word = sentence.words.first {
              if state.stage == 0 {
                WordPronunciationView(sentence: sentence, wordID: word.id,
                  onEditTiming: { _ in }, onClose: {}).environment(store)
              } else if state.stage == 4 {
                ImportProgressSheet(presentation: ImportPreparationFixtures.progress,
                  onContinueBrowsing: {}, onCancelImport: {})
              } else if state.stage == 5 {
                ImportReadySheet(presentation: ImportReadyPresentation(
                  lessonTitle: String(repeating: "A long lesson title with transcript details. ", count: 24),
                  contentSummary: ImportPreparationFixtures.ready.contentSummary,
                  practiceSummary: ImportPreparationFixtures.ready.practiceSummary),
                  onStartPracticing: {}, onBackToLibrary: {})
              } else if state.stage >= 6 {
                RepeatOptionsView(onClose: {}, initiallyExpanded: state.stage == 6)
                  .id(state.stage).environment(store)
              } else {
                TimingEditorView(lesson: lesson, sentence: sentence, wordID: word.id,
                  onClose: {}, usesSimulatedWaveform: false,
                  waveformError: state.stage >= 2 ? "Waveform unavailable" : nil)
                  .environment(store)
              }
            }
          }
          .environment(\.locale, store.preferences.language.locale)
        }
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
