#if DEBUG
  import SwiftUI
  import AppKit

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
