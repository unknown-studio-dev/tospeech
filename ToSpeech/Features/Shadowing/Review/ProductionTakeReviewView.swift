import SwiftUI

enum TakeReviewPage: Hashable { case overview, phone, guide, delivery, signals, content, details }
enum TakeReviewPresentation { case page, drawer }

private struct ReviewDrawerPriority: Identifiable {
  let word: WordPronunciationEvidence
  let phone: PhoneDifference
  let quality: PronunciationQuality
  var id: ReviewPhoneSelection { .init(wordID: word.id, phoneID: phone.id) }
}

struct RecordingManagerSheet: View {
  @Environment(\.locale) private var locale
  let recordings: [PracticeTake]
  let loadByteCounts: () async -> [UUID: Int64]
  let delete: (Set<UUID>) async throws -> Int64
  let close: () -> Void

  @State private var selectedIDs: Set<String> = []
  @State private var byteCounts: [UUID: Int64] = [:]
  @State private var confirming = false
  @State private var deleting = false
  @State private var error: String?

  init(
    recordings: [PracticeTake],
    initialSelection: Set<String> = [],
    initiallyConfirming: Bool = false,
    loadByteCounts: @escaping () async -> [UUID: Int64],
    delete: @escaping (Set<UUID>) async throws -> Int64,
    close: @escaping () -> Void
  ) {
    self.recordings = recordings
    self.loadByteCounts = loadByteCounts
    self.delete = delete
    self.close = close
    _selectedIDs = State(initialValue: initialSelection)
    _confirming = State(initialValue: initiallyConfirming)
  }

  private var sortedRecordings: [PracticeTake] {
    recordings.sorted { $0.createdAt > $1.createdAt }
  }

  private var selectedRecordings: [PracticeTake] {
    sortedRecordings.filter { selectedIDs.contains($0.id) }
  }

  private var selectedBytes: Int64 {
    selectedRecordings.reduce(0) { partial, take in
      partial + (UUID(uuidString: take.id).flatMap { byteCounts[$0] } ?? 0)
    }
  }

  private var allSelected: Bool {
    !recordings.isEmpty && selectedIDs.count == recordings.count
  }

  private var partlySelected: Bool {
    !selectedIDs.isEmpty && !allSelected
  }

  var body: some View {
    EchoDialog(
      title: confirming ? "recordings.delete.title" : "recordings.manage.title",
      subtitle: confirming ? "recordings.delete.subtitle" : "recordings.manage.subtitle",
      width: 640,
      height: 600,
      close: {
        guard !deleting else { return }
        if confirming { confirming = false }
        else { close() }
      }
    ) {
      if confirming { confirmationBody }
      else { selectionBody }
    } footer: {
      if confirming {
        EchoButton("recordings.keep", size: .regular) { confirming = false }
          .disabled(deleting)
        EchoButton(
          "recordings.delete.confirm",
          symbol: "trash",
          kind: .destructive,
          size: .regular,
          state: deleting ? .loading("recordings.deleting") : .idle
        ) { performDeletion() }
      } else {
        EchoButton("Cancel", size: .regular, action: close)
        EchoButton(
          "recordings.delete.selected",
          symbol: "trash",
          kind: .danger,
          size: .regular
        ) {
          error = nil
          confirming = true
        }
        .disabled(selectedIDs.isEmpty)
      }
    }
    .interactiveDismissDisabled(deleting)
    .task { byteCounts = await loadByteCounts() }
  }

  private var selectionBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        EchoCheckbox(
          title: "recordings.select_all",
          isOn: Binding(
            get: { allSelected },
            set: { selected in
              selectedIDs = selected ? Set(recordings.map(\.id)) : []
            }
          ),
          isMixed: Binding(get: { partlySelected }, set: { _ in })
        )
        Spacer()
        Text(selectionSummary)
          .font(EchoFont.metadata)
          .foregroundStyle(EchoTheme.secondaryText)
      }
      Divider().overlay(EchoTheme.separator)
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(sortedRecordings) { take in
            recordingRow(take)
          }
        }
        .padding(.vertical, 2)
      }
      .scrollIndicators(.automatic)
      if let error {
        EchoNotice(copy: EchoCopy("storage.detail", arguments: [.raw(error)]), error: true)
      }
    }
  }

  private var confirmationBody: some View {
    VStack(alignment: .leading, spacing: 16) {
      EchoNotice(text: "recordings.delete.warning", error: true)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(selectedRecordings.prefix(6)) { take in
          HStack {
            Text(recordingTitle(take)).font(EchoFont.body(size: 13, weight: .medium))
            Spacer()
            Text(byteLabel(take)).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          }
        }
        if selectedRecordings.count > 6 {
          Text(verbatim: EchoLocalization.format(
            "recordings.more",
            locale: locale,
            arguments: [selectedRecordings.count - 6]
          ))
          .font(EchoFont.metadata)
          .foregroundStyle(EchoTheme.secondaryText)
        }
      }
      .padding(14)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      Text(verbatim: EchoLocalization.format(
        "recordings.delete.summary",
        locale: locale,
        arguments: [selectedRecordings.count, formatBytes(selectedBytes)]
      ))
      .font(EchoFont.body(size: 13, weight: .semibold))
      if let error {
        EchoNotice(copy: EchoCopy("storage.detail", arguments: [.raw(error)]), error: true)
      }
      Spacer(minLength: 0)
    }
  }

  private func recordingRow(_ take: PracticeTake) -> some View {
    HStack(spacing: 12) {
      EchoCheckbox(
        title: recordingTitle(take),
        isOn: Binding(
          get: { selectedIDs.contains(take.id) },
          set: { selected in
            if selected { selectedIDs.insert(take.id) }
            else { selectedIDs.remove(take.id) }
          }
        )
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: take.sourceSnapshot.text)
          .font(EchoFont.body(size: 12))
          .lineLimit(1)
        Text(verbatim: EchoLocalization.format(
          "recordings.metadata",
          locale: locale,
          arguments: [
            take.createdAt.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            ),
            EchoFormat.time(take.duration),
            byteLabel(take),
          ]
        ))
        .font(EchoFont.metadata)
        .foregroundStyle(EchoTheme.secondaryText)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 58)
    .background(
      selectedIDs.contains(take.id) ? EchoTheme.selection : EchoTheme.surface,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(
      selectedIDs.contains(take.id) ? EchoTheme.accent : EchoTheme.border
    ))
  }

  private var selectionSummary: String {
    EchoLocalization.format(
      "recordings.selected_summary",
      locale: locale,
      arguments: [selectedIDs.count, formatBytes(selectedBytes)]
    )
  }

  private func recordingTitle(_ take: PracticeTake) -> String {
    EchoLocalization.format(
      "recordings.row_title",
      locale: locale,
      arguments: [take.number, take.sourceSnapshot.number]
    )
  }

  private func byteLabel(_ take: PracticeTake) -> String {
    guard let id = UUID(uuidString: take.id), let bytes = byteCounts[id], bytes > 0 else {
      return EchoLocalization.string("recordings.size.calculating", locale: locale)
    }
    return formatBytes(bytes)
  }

  private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func performDeletion() {
    guard !deleting else { return }
    let ids = Set(selectedIDs.compactMap(UUID.init(uuidString:)))
    guard !ids.isEmpty else { return }
    deleting = true
    error = nil
    Task {
      do {
        _ = try await delete(ids)
        close()
      } catch {
        self.error = error.localizedDescription
        deleting = false
      }
    }
  }
}

/// D02g–i: one review route with a persistent sentence and playback transport.
struct ProductionTakeReviewView<Source: View>: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  let layout: ShadowingLayout
  let take: PracticeTake
  let runtime: ReviewRuntimePresentation
  let onBack: () -> Void
  let onRecordAgain: () -> Void
  @ViewBuilder let source: () -> Source
  var fixtureHistory: [PronunciationJob]? = nil
  var initialPage: TakeReviewPage = .overview
  var initialDimension: DeliveryDimension = .intonation
  var presentation: TakeReviewPresentation = .page
  @State private var selectedJobID: UUID?
  @State private var selection: ReviewPhoneSelection?
  @State private var page: TakeReviewPage
  @State private var dimension: DeliveryDimension
  @State private var recordingAgain = false
  @State private var coachSpeech = AppleReferenceSpeechPlayer()
  @State private var phonemeAudio = UKPhonemeAudioPlayer()
  @State private var guideSymbol = "iː"

  init(
    layout: ShadowingLayout, take: PracticeTake, runtime: ReviewRuntimePresentation,
    onBack: @escaping () -> Void, onRecordAgain: @escaping () -> Void,
    @ViewBuilder source: @escaping () -> Source, fixtureHistory: [PronunciationJob]? = nil,
    initialPage: TakeReviewPage = .overview,
    initialDimension: DeliveryDimension = .intonation,
    presentation: TakeReviewPresentation = .page
  ) {
    self.layout = layout
    self.take = take
    self.runtime = runtime
    self.onBack = onBack
    self.onRecordAgain = onRecordAgain
    self.source = source
    self.fixtureHistory = fixtureHistory
    self.initialPage = initialPage
    self.initialDimension = initialDimension
    self.presentation = presentation
    _page = State(initialValue: initialPage)
    _dimension = State(initialValue: initialDimension)
  }

  private var history: [PronunciationJob] {
    fixtureHistory ?? UUID(uuidString: take.id).map { runtime.assessmentService?.history(takeID: $0) ?? [] } ?? []
  }
  private var job: PronunciationJob? { history.first { $0.id == selectedJobID } ?? history.last }
  private var evidence: PronunciationEvidence? { job?.result }
  private var eligible: Bool { [.complete, .earlyStop].contains(take.outcome) }
  private var selectedWord: WordPronunciationEvidence? { evidence?.words.first { $0.id == selection?.wordID } }
  private var selectedPhone: PhoneDifference? { selectedWord?.phones.first { $0.id == selection?.phoneID } }
  private var selectedXeusGroup: XeusReferenceDiagnostics.Group? {
    guard let word = selectedWord, let phone = selectedPhone, let xeus = evidence?.phoneticXeus,
      let rows = xeus.words.first(where: { $0.id == word.id })?.phones,
      rows.indices.contains(phone.id), let diagnostic = rows[phone.id].diagnostic else { return nil }
    return xeus.reference?.groups.first { $0.id == diagnostic.groupID }
  }
  private var preferredPhone: ReviewPhoneSelection? {
    for quality in [PronunciationQuality.incorrect, .nearCorrect, .correct, .unassessed] {
      for word in evidence?.words ?? [] {
        if let phone = word.phones.first(where: { PronunciationDisplay.quality($0, supported: word.supported) == quality }) {
          return .init(wordID: word.id, phoneID: phone.id)
        }
      }
    }
    return nil
  }
  private var sourceOffset: Double { job.map { Double($0.target.startFrame)/Double($0.target.sampleRate) } ?? take.sourceSnapshot.span.start }
  private var drawerContentWidth: CGFloat { max(0, layout.reviewDrawerWidth - 40) }
  private func copy(_ key: String) -> String { EchoLocalization.string(key, locale: locale) }

  var body: some View {
    Group {
      if presentation == .drawer { drawer }
      else { pageBody }
    }
    .onAppear {
      if page == .phone, selection == nil { selection = preferredPhone }
    }
    .onChange(of: job?.id) { stopPlayback(); selection = nil; page = .overview }
    .onChange(of: selection) { stopPlayback() }
    .onChange(of: page) { stopPlayback() }
    .onChange(of: guideSymbol) { _, symbol in
      phonemeAudio.stopIfPlayingDifferentSound(from: symbol)
    }
    .onDisappear {
      coachSpeech.stop()
      phonemeAudio.stop()
      if !recordingAgain { runtime.onStop?() }
    }
  }

  private var pageBody: some View {
    ScrollViewReader { reader in
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if layout.contentWidth >= 760 {
          HStack(alignment: .top, spacing: 24) {
            source().frame(width: layout.videoWidth)
            panel.echoContentReveal(value: page).frame(width: layout.transcriptWidth)
          }
        } else {
          source().frame(maxWidth: .infinity)
          panel.echoContentReveal(value: page)
        }
        AssessedSentenceView(sentence: take.sourceSnapshot, evidence: evidence,
          accent: job?.accent ?? store.preferences.accent, scale: layout.readingScale,
          selection: selection, onOpenLibrary: { page = .guide }, playingWordID: playingWordID) { selection = $0; page = .phone }
        ReviewSignalComparisonView(take: take, runtime: runtime, evidence: evidence?.delivery,
          onPreparePlayback: stopPlayback)
        if page == .phone, (job?.accent ?? store.preferences.accent) == .uk, let expected = selectedPhone?.expected {
          UKSoundCoachView(symbol: expected, onSpeak: speakExample)
        }
        if page == .guide { UKSoundCoachView(symbol: guideSymbol, onSpeak: speakExample) }
        if page == .delivery, let uk = evidence?.ukReference {
          UKDeliveryReviewView(dimension: dimension, evidence: uk, sourceOffset: sourceOffset) {
            runtime.onCompareDetail?($0, $1)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 20) { transport.background(EchoTheme.canvas) }
    .onChange(of: playingWordID, initial: true) { _, wordID in
      // With no anchor SwiftUI only scrolls enough to reveal an offscreen word.
      // Long sentences remain readable above the persistent transport.
      if let wordID { reader.scrollTo(wordID) }
    }
    }
  }

  private var drawer: some View {
    VStack(spacing: 0) {
      drawerHeader
      Divider().overlay(EchoTheme.separator)
      CompactAssessedSentenceView(
        sentence: take.sourceSnapshot, evidence: evidence,
        accent: job?.accent ?? store.preferences.accent
      ) { selection = $0; page = .phone }
      .frame(width: drawerContentWidth, alignment: .leading)
      .padding(.top, 20)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let error = coachSpeech.errorKey ?? phonemeAudio.errorKey {
            EchoNotice(text: error, error: true)
          }
          drawerPage
        }
        .frame(width: drawerContentWidth, alignment: .leading)
        .padding(.vertical, 20)
      }
      .frame(maxWidth: .infinity)
      .scrollIndicators(.automatic)
      Divider().overlay(EchoTheme.separator)
      drawerFooter
    }
    .frame(width: layout.reviewDrawerWidth)
    .frame(maxHeight: .infinity)
    .foregroundStyle(EchoTheme.text)
    .background(EchoTheme.surface)
    .overlay(alignment: .leading) { Rectangle().fill(EchoTheme.border.opacity(0.55)).frame(width: 1) }
    .shadow(color: EchoTheme.canvas.opacity(0.55), radius: 22, x: -10)
    .onExitCommand(perform: onBack)
  }

  private var drawerHeader: some View {
    VStack(spacing: 5) {
      HStack(spacing: 10) {
        if page != .overview {
          EchoIconButton(symbol: "chevron.left", label: "review.overview") {
            selection = nil
            page = .overview
          }
        }
        EchoLocalizedText(drawerTitle)
          .font(EchoFont.body(size: 17, weight: .semibold))
          .lineLimit(1).minimumScaleFactor(0.82)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
        EchoIconButton(symbol: "xmark", label: "review.drawer.close", action: onBack)
      }
      HStack(spacing: 10) {
        Text(verbatim: EchoLocalization.format("review.drawer.metadata", locale: locale,
          arguments: [take.number, take.sourceSnapshot.number]))
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        Spacer(minLength: 8)
        if page == .overview {
          EchoSelect(label: "Saved recordings", selection: Binding(get: { take.id }, set: {
            stopPlayback(); runtime.onSelectTake($0)
          }), options: runtime.history.map {
            ($0.id, EchoLocalization.format("review.take", locale: locale, arguments: [$0.number]))
          }).fixedSize(horizontal: true, vertical: false)
          if let manage = runtime.onManageRecordings {
            EchoIconButton(symbol: "trash", label: "recordings.manage.action", action: manage)
          }
        }
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .frame(width: layout.reviewDrawerWidth)
  }

  private var drawerTitle: String {
    switch page {
    case .overview: "review.recording_title"
    case .phone: "review.drawer.sound_detail"
    case .delivery: "review.drawer.delivery_detail"
    case .signals: "review.signal.title"
    case .content: "review.content"
    case .details: "review.details"
    case .guide: "coach.library"
    }
  }

  @ViewBuilder private var drawerPage: some View {
    switch page {
    case .overview: drawerOverview
    case .phone:
      phoneDetail
      if (job?.accent ?? store.preferences.accent) == .uk, let expected = selectedPhone?.expected {
        UKSoundCoachView(symbol: expected, onSpeak: speakExample)
      }
    case .delivery:
      DeliveryComparisonView(dimension: $dimension, evidence: evidence?.delivery,
        sourceOffset: sourceOffset) { runtime.onCompareDetail?($0, $1) }
      if evidence?.delivery?.source == nil { assessAction }
    case .signals:
      ReviewSignalComparisonView(take: take, runtime: runtime, evidence: evidence?.delivery,
        onPreparePlayback: stopPlayback)
    case .content: contentReview
    case .details: details
    case .guide: UKSoundLibraryView(
      selectedSymbol: $guideSymbol, onSpeak: speakExample, onSpeakSound: speakSound,
      playingSymbol: phonemeAudio.playingSymbol)
    }
  }

  @ViewBuilder private var drawerOverview: some View {
    if !eligible {
      EchoNotice(text: "review.outcome.\(take.outcome.rawValue)",
        error: take.outcome == .noSpeech || take.outcome == .quiet)
    } else {
      if take.outcome == .earlyStop { EchoNotice(text: "review.outcome.earlyStop") }
      if let error = runtime.assessmentService?.error {
        EchoNotice(text: copy(error), error: true)
        EchoButton("Retry") { selectedJobID = nil; runtime.onAssess?() }
      }
      if let job, job.isPending { EchoLoading(title: "assessment.status.\(job.status.rawValue)") }
      if let error = job?.error { EchoNotice(text: copy(error), error: true) }

      if let evidence {
        let coverage = PronunciationCoverage(evidence)
        let counts = coverage.counts
        drawerScore(coverage: coverage, counts: counts)

        if !drawerPriorities.isEmpty {
          Eyebrow("review.drawer.priorities")
          VStack(spacing: 6) {
            ForEach(drawerPriorities) { item in drawerPriorityRow(item) }
          }
        }

        drawerNavigationRow("review.drawer.sound_detail", value: copy("review.select_phone"),
          symbol: "waveform", color: counts[.incorrect, default: 0] > 0 ? EchoTheme.danger
            : counts[.nearCorrect, default: 0] > 0 ? EchoTheme.caution
            : coverage.summary == .matched ? EchoTheme.success : EchoTheme.secondaryText) {
          selection = preferredPhone
          page = selection == nil ? .details : .phone
        }
        drawerNavigationRow("review.drawer.delivery_detail",
          value: deliverySummary(.intonation), symbol: "waveform.path.ecg",
          color: evidence.delivery?.source == nil ? EchoTheme.secondaryText : EchoTheme.accent) {
          dimension = .stress; selection = nil; page = .delivery
        }
      } else if job?.isPending != true {
        EchoNotice(text: "assessment.empty_active")
      }

      if job == nil || job?.status == .failed || evidence?.delivery == nil { assessAction }

      WordFlowLayout(spacing: 8, lineSpacing: 8) { playbackButtons }

      EchoDisclosureGroup("review.drawer.more") {
        VStack(spacing: 4) {
          drawerNavigationRow("review.signal.title", value: copy("review.drawer.open"),
            symbol: "waveform.path", color: EchoTheme.secondaryText) { page = .signals }
          drawerNavigationRow("review.content", value: contentSummary,
            symbol: "text.alignleft", color: EchoTheme.secondaryText) { page = .content }
          drawerNavigationRow("review.details", value: job?.engineTitle ?? copy("Not assessed"),
            symbol: "info.circle", color: EchoTheme.secondaryText) { page = .details }
          if (job?.accent ?? store.preferences.accent) == .uk {
            drawerNavigationRow("coach.library", value: copy("review.drawer.open"),
              symbol: "book", color: EchoTheme.secondaryText) { page = .guide }
          }
        }.padding(.top, 6)
      }
      .font(EchoFont.body(size: 13))
    }
  }

  private func drawerScore(
    coverage: PronunciationCoverage, counts: [PronunciationQuality: Int]
  ) -> some View {
    let summary = coverage.summary
    let color = summary == .unassessed || summary == .partial
      ? EchoTheme.secondaryText : EchoTheme.accent
    return HStack(spacing: 14) {
      ZStack {
        Circle().fill(summary == .unassessed || summary == .partial
          ? EchoTheme.soft : EchoTheme.selection)
        Circle().stroke(color, lineWidth: 3)
        if coverage.assessed > 0, let job, job.status == .complete,
          let score = take.assessments.first(where: { $0.id == job.id.uuidString })?.score {
          Text(verbatim: "\(Int(score.rounded()))")
            .font(EchoFont.heading(size: 25)).monospacedDigit()
        } else {
          Image(systemName: summary.symbol)
            .font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
        }
      }.frame(width: 66, height: 66)
      VStack(alignment: .leading, spacing: 5) {
        EchoLocalizedText(summary.title)
          .font(EchoFont.body(size: 16, weight: .semibold))
        Text(verbatim: EchoLocalization.format("review.coverage_counts", locale: locale,
          arguments: [counts[.correct, default: 0], counts[.nearCorrect, default: 0],
            counts[.incorrect, default: 0], counts[.unassessed, default: 0]]))
          .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: EchoLocalization.format("review.coverage", locale: locale,
          arguments: [coverage.assessed, coverage.total]))
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
    }
  }

  private var drawerPriorities: [ReviewDrawerPriority] {
    let qualities: [PronunciationQuality] = [.incorrect, .nearCorrect]
    return qualities.flatMap { quality in
      (evidence?.words ?? []).flatMap { word in
        word.phones.compactMap { phone in
          PronunciationDisplay.quality(phone, supported: word.supported) == quality
            ? ReviewDrawerPriority(word: word, phone: phone, quality: quality) : nil
        }
      }
    }.prefix(3).map { $0 }
  }

  private func drawerPriorityRow(_ item: ReviewDrawerPriority) -> some View {
    EchoRowButton(minimumHeight: 54) {
      selection = .init(wordID: item.word.id, phoneID: item.phone.id)
      page = .phone
    } content: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: item.word.target.text).font(EchoFont.body(size: 15, weight: .semibold))
          Text(verbatim: item.phone.expected.map { "/\($0)/" } ?? "∅")
            .font(EchoFont.body(size: 12)).foregroundStyle(item.quality.color)
        }
        Spacer()
        Label(EchoLocalization.string(item.quality.title, locale: locale),
          systemImage: item.quality.symbol).foregroundStyle(item.quality.color)
          .font(EchoFont.body(size: 11))
        Image(systemName: "chevron.right").font(.system(size: 10))
          .foregroundStyle(EchoTheme.secondaryText)
      }
    }
    .background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: 9))
  }

  private func drawerNavigationRow(
    _ title: String, value: String, symbol: String, color: Color,
    action: @escaping () -> Void
  ) -> some View {
    EchoRowButton(minimumHeight: 38, action: action) {
      HStack(spacing: 9) {
        Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          EchoLocalizedText(title).foregroundStyle(EchoTheme.text)
          Text(verbatim: value).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
            .lineLimit(2)
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.right").font(.system(size: 10))
          .foregroundStyle(EchoTheme.secondaryText)
      }
    }
  }

  private var drawerFooter: some View {
    VStack(spacing: 8) {
      EchoButton("Record sentence again", symbol: "mic", kind: .primary,
        size: .regular, minimumWidth: 240) {
        stopPlayback(); recordingAgain = true; onRecordAgain()
      }
      EchoButton("review.drawer.continue", symbol: "xmark", kind: .ghost,
        minimumWidth: 240, action: onBack)
    }
    .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 12)
    .background(EchoTheme.surface)
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if page == .overview {
        HStack {
          EchoLocalizedText("review.recording_title").font(EchoFont.heading(size: 22))
          Spacer()
          Text(verbatim: EchoLocalization.format("review.sentence", locale: locale, arguments: [take.sourceSnapshot.number]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
      } else {
        EchoButton("review.overview", symbol: "chevron.left", kind: .ghost) { page = .overview; selection = nil }
      }
      HStack {
          EchoSelect(label: "Saved recordings", selection: Binding(get: { take.id }, set: {
            stopPlayback(); runtime.onSelectTake($0)
          }), options: runtime.history.map { ($0.id, EchoLocalization.format("review.take", locale: locale, arguments: [$0.number])) })
          .fixedSize(horizontal: true, vertical: false)
          Text(verbatim: job == nil ? copy("Not assessed") : (job?.engineTitle ?? "") + " · " + copy(evidence?.ukReference == nil ? "review.local" : "assessment.uk.experimental"))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
      if history.count > 1 {
        EchoSelect(label: "Assessment history", selection: Binding(get: { job?.id.uuidString ?? "" }, set: {
          selectedJobID = UUID(uuidString: $0); selection = nil
        }), options: history.map { ($0.id.uuidString, "\($0.createdAt.formatted(date: .abbreviated, time: .shortened)) · \($0.engineTitle) · \(copy("assessment.status.\($0.status.rawValue)"))") })
      }
      if page != .overview {
      WordFlowLayout(spacing: 6, lineSpacing: 6) {
        EchoButton("review.overview", kind: page == .overview ? .primary : .ghost) { page = .overview }
        EchoButton("review.sounds", kind: page == .phone ? .primary : .ghost) {
          selection = preferredPhone; page = .phone
        }
        EchoButton("review.content", kind: page == .content ? .primary : .ghost) { page = .content }
        ForEach(DeliveryDimension.allCases) { item in
          EchoButton(item.title, kind: page == .delivery && dimension == item ? .primary : .ghost) {
            dimension = item; page = .delivery; selection = nil
          }
        }
      }
      }
      if let error = coachSpeech.errorKey ?? phonemeAudio.errorKey {
        EchoNotice(text: error, error: true)
      }
      switch page {
      case .overview: overview
      case .phone: phoneDetail
      case .guide: UKSoundLibraryView(
        selectedSymbol: $guideSymbol, onSpeak: speakExample, onSpeakSound: speakSound,
        playingSymbol: phonemeAudio.playingSymbol, showsDetail: false)
      case .delivery:
        DeliveryComparisonView(dimension: $dimension, evidence: evidence?.delivery, sourceOffset: sourceOffset, showsNavigation: false) {
          runtime.onCompareDetail?($0, $1)
        }
        if evidence?.delivery?.source == nil { assessAction }
      case .signals:
        ReviewSignalComparisonView(take: take, runtime: runtime, evidence: evidence?.delivery,
          onPreparePlayback: stopPlayback)
      case .content: contentReview
      case .details: details
      }
    }.foregroundStyle(EchoTheme.text)
  }

  @ViewBuilder private var overview: some View {
    if !eligible {
      EchoNotice(text: "review.outcome.\(take.outcome.rawValue)", error: take.outcome == .noSpeech || take.outcome == .quiet)
    } else {
      if take.outcome == .earlyStop { EchoNotice(text: "review.outcome.earlyStop") }
      if let error = runtime.assessmentService?.error {
        EchoNotice(text: copy(error), error: true)
        EchoButton("Retry") { selectedJobID = nil; runtime.onAssess?() }
      }
      if let job, job.isPending { EchoLoading(title: "assessment.status.\(job.status.rawValue)") }
      if let error = job?.error { EchoNotice(text: copy(error), error: true) }
      if let evidence {
        let coverage = PronunciationCoverage(evidence)
        let counts = coverage.counts
        if let xeus = evidence.phoneticXeus {
          if let reference = xeus.reference {
            Text(verbatim: EchoLocalization.format("assessment.reference.coverage", locale: locale,
              arguments: [reference.groups.flatMap(\.members).count, reference.groups.count]))
              .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          } else {
            let supported = xeus.words.flatMap(\.phones).filter { $0.expectedProbability != nil }.count
            Text(verbatim: EchoLocalization.format("assessment.xeus.coverage", locale: locale,
              arguments: [supported, coverage.total])).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          }
        }
        Text(verbatim: EchoLocalization.format("review.coverage", locale: locale,
          arguments: [coverage.assessed, coverage.total]))
          .font(EchoFont.body(size: 18, weight: .semibold))
        Text(verbatim: EchoLocalization.format("review.coverage_counts", locale: locale,
          arguments: [counts[.correct, default: 0], counts[.nearCorrect, default: 0],
            counts[.incorrect, default: 0], counts[.unassessed, default: 0]]))
          .font(EchoFont.body(size: 14)).fixedSize(horizontal: false, vertical: true)
        reviewRow("review.sounds", value: copy("review.select_phone"), symbol: "waveform",
          color: counts[.incorrect, default: 0] > 0 ? EchoTheme.danger : counts[.nearCorrect, default: 0] > 0 ? EchoTheme.caution : EchoTheme.secondaryText) {
          selection = preferredPhone
          page = selection == nil ? .details : .phone
        }
        if counts[.unassessed, default: 0] > 0 {
          if evidence.phoneticXeus != nil {
            // Coverage counts display reasons, so near-correct rows never land in either bucket.
            let referenceSide = [.referenceUncertain, .referenceUnmapped, .referenceWeak, .modelCannotDistinguish]
              .reduce(0) { $0 + coverage.reasons[$1, default: 0] }
            Text(verbatim: EchoLocalization.format("assessment.xeus.unresolved_origins", locale: locale,
              arguments: [referenceSide, counts[.unassessed, default: 0] - referenceSide]))
              .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          } else {
          let outside = coverage.reasons[.outsideModel, default: 0]
          Text(verbatim: EchoLocalization.format("review.coverage_detail", locale: locale,
            arguments: [outside, counts[.unassessed, default: 0] - outside]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else if job?.isPending != true {
        EchoLocalizedText([EngineID.buddy, .phone, .ukReference, .phoneticXeus].contains(store.preferences.productionAssessmentEngine ?? .compact) ? "assessment.empty_active" : "assessment.empty")
          .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      }
      if evidence == nil {
        reviewRow("review.sounds", value: copy("Not assessed"), symbol: "waveform", color: EchoTheme.secondaryText) { page = .phone }
      }
      VStack(spacing: 0) {
      ForEach(DeliveryDimension.allCases) { item in
        reviewRow(item.title, value: deliverySummary(item),
          symbol: item.symbol, color: evidence?.delivery?.source == nil ? EchoTheme.secondaryText : EchoTheme.accent) {
          dimension = item; page = .delivery; selection = nil
        }
      }
      }
      reviewRow("review.content", value: contentSummary, symbol: "text.alignleft", color: EchoTheme.secondaryText) { page = .content }
      if job == nil || job?.status == .failed || evidence?.delivery == nil { assessAction }
    }
    WordFlowLayout(spacing: 8, lineSpacing: 8) {
      EchoButton("coach.library", symbol: "book", kind: .ghost) { page = .guide }
      EchoButton("review.details", symbol: "chevron.right", kind: .ghost) { page = .details }
    }
  }

  @ViewBuilder private var phoneDetail: some View {
    if let word = selectedWord, let phone = selectedPhone {
      let quality = PronunciationDisplay.quality(phone, supported: word.supported)
      Text(verbatim: word.target.text).font(EchoFont.heading(size: 28))
      Label(copy(quality.title), systemImage: quality.symbol).foregroundStyle(quality.color)
      if let evidence, let reason = PronunciationCoverage.reason(phone, word: word, evidence: evidence) {
        EchoNotice(text: reason == .takeUncertain && selectedXeusGroup?.hasMatchingSequence == true
          ? "assessment.reference.match_pending" : reason.title)
      }
      if let xeus = evidence?.phoneticXeus,
        let rows = xeus.words.first(where: { $0.id == word.id })?.phones, rows.indices.contains(phone.id) {
        if let detail = rows[phone.id].diagnostic,
          let group = xeus.reference?.groups.first(where: { $0.id == detail.groupID }) {
          XeusReferenceDetailView(detail: detail, group: group, policy: xeus.policy)
        } else {
        EchoLocalizedText("assessment.xeus.evidence_hint").font(EchoFont.body(size: 14))
        if let probability = rows[phone.id].expectedProbability {
          Text(verbatim: String(format: "%@ %.3f", copy("assessment.xeus.support"), probability)).font(EchoFont.metadata)
        }
        if let margin = rows[phone.id].logMargin {
          Text(verbatim: String(format: "%@ %.2f", copy("assessment.xeus.margin"), margin)).font(EchoFont.metadata)
        }
        }
        let row = rows[phone.id]
        if row.referenceMatch != nil {
          Text(verbatim: EchoLocalization.format("assessment.xeus.reference_match", locale: locale,
            arguments: [row.referenceMatch == true ? copy("common.yes") : copy("common.no")]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
        if let licence = row.licence {
          Text(verbatim: "\(copy("assessment.xeus.licence")) \(licence)")
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
      }
      if evidence?.phoneticXeus == nil, let uk = evidence?.ukReference,
        let measurements = uk.measurements[word.id], measurements.indices.contains(phone.id) {
        let measured = measurements[phone.id]
        EchoLocalizedText("assessment.uk.reference_hint").font(EchoFont.body(size: 14))
        if quality == .nearCorrect { EchoLocalizedText("assessment.uk.near_policy") }
        EchoDisclosureGroup("review.details") {
          Text(verbatim: String(format: "%@ %.3f", copy("assessment.uk.distance"), measured.acousticDistance))
          if let sourceVowel = measured.sourceVowel, let takeVowel = measured.predictedVowel {
            Text(verbatim: "\(copy("Original sentence")): /\(sourceVowel)/ → \(copy("Your full take")): /\(takeVowel)/")
            EchoLocalizedText("assessment.uk.category_hint")
          }
          Text(verbatim: uk.calibration)
        }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
      if let score = phone.score {
        Text(verbatim: String(format: "%.1f / 100 · US", score)).font(EchoFont.heading(size: 28))
        if let unit = phone.scoredUnit, unit != phone.expected {
          Text(verbatim: EchoLocalization.format("assessment.phone_scorer.shared_unit", locale: locale, arguments: [unit]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
        if let source = phone.sourceScore {
          Text(verbatim: EchoLocalization.format("assessment.phone_scorer.reference_score", locale: locale, arguments: [source]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
      }
      HStack(spacing: 28) {
        sound("review.expected_phone", phone.expected)
        if phone.score == nil && evidence?.phoneticXeus?.reference == nil {
          Image(systemName: "arrow.left.arrow.right").foregroundStyle(EchoTheme.secondaryText)
          if phone.observed == nil && phone.kind != .omission {
            VStack(alignment: .leading, spacing: 6) {
              EchoLocalizedText("review.observed_phone").font(EchoFont.metadata)
              EchoLocalizedText("review.observed_unknown").font(EchoFont.body(size: 16))
            }.foregroundStyle(EchoTheme.secondaryText)
          } else { sound("review.observed_phone", phone.observed, color: quality.color) }
        }
      }
      if quality != .unassessed {
        EchoLocalizedText(evidence?.ukReference != nil && phone.kind == .scored
          ? "assessment.uk.category_hint" : "assessment.phone.\(phone.kind.rawValue)").font(EchoFont.body(size: 14))
      }
      WordFlowLayout(spacing: 8, lineSpacing: 8) {
        if let span = sourceSpan(word, phone: phone) {
          EchoButton("assessment.hear_source", symbol: "speaker.wave.2") { coachSpeech.stop(); runtime.onReferenceDetail?(span.start, span.end) }
        }
        if let span = takeSpan(word, phone: phone) {
          EchoButton("assessment.hear_region", symbol: "play.fill") { coachSpeech.stop(); runtime.onReplayDetail?(span.start, span.end) }
          if let source = sourceSpan(word, phone: phone) {
            EchoButton("A → B", symbol: "headphones") { coachSpeech.stop(); runtime.onCompareDetail?(source, span) }
          }
        }
      }
      EchoLocalizedText("review.phone_region_hint").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      if let result = evidence {
        let candidates = result.words.flatMap { word in word.phones.map { (word.id, $0.id) } }
        if let index = candidates.firstIndex(where: { $0.0 == word.id && $0.1 == phone.id }), candidates.count > 1 {
          EchoButton("review.next_phone", symbol: "arrow.right", kind: .ghost) {
            let next = candidates[(index+1)%candidates.count]; selection = .init(wordID: next.0, phoneID: next.1)
          }
        }
      }
    } else { EchoNotice(text: "review.select_phone"); assessAction }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let job {
        Text(verbatim: job.provenance).textSelection(.enabled)
        Text(verbatim: "\(job.accent.rawValue) · \(job.target.segmentRevisionID.uuidString)")
        Text(verbatim: "SHA256 \(job.audioChecksum)").textSelection(.enabled)
        Text(verbatim: [evidence?.qualityPolicy, evidence?.delivery?.policy].compactMap { $0 }.joined(separator: " · "))
        EchoLocalizedText(job.provenance.hasPrefix("PhoneticXeus") ? "assessment.xeus.details" : job.provenance.hasPrefix("UK Reference") ? "assessment.uk.details" : job.provenance.hasPrefix("Phone Scorer") ? "assessment.phone_scorer.details" : "review.quality_policy")
        if let error = evidence?.phoneticXeus?.deliveryError { Text(verbatim: error) }
        if job.provenance.hasPrefix("Buddy") { EchoLocalizedText("assessment.limitations") }
      }
      assessAction
    }.font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
  }

  private var contentSummary: String {
    guard let id = UUID(uuidString: take.id), let job = runtime.matchingService?.history(takeID: id).last else { return copy("Not assessed") }
    if let match = job.match { return copy(match.differences.isEmpty ? "review.content_matches" : "review.content_check") }
    return copy("assessment.status.\(job.status.rawValue)")
  }
  @ViewBuilder private var contentReview: some View {
    if let service = runtime.matchingService, let id = UUID(uuidString: take.id) {
      ContentMatchingReviewView(history: service.history(takeID: id), error: service.error,
        onRetry: { job in Task { await service.retry(job) } }, onRecover: { Task { await service.recover() } })
      EchoButton("matching.rerun") { runtime.onMatch?() }.disabled(!eligible || service.history(takeID: id).contains(where: \.isPending))
    } else { EchoNotice(text: "matching.not_started") }
  }

  @ViewBuilder private var assessAction: some View {
    if eligible {
      if [EngineID.buddy, .phone, .ukReference, .phoneticXeus].contains(store.preferences.productionAssessmentEngine ?? .compact) {
        EchoButton(history.isEmpty ? "assessment.start" : "assessment.rerun", symbol: "waveform", kind: history.isEmpty ? .primary : .secondary) {
          selectedJobID = nil; runtime.onAssess?()
        }.disabled(history.contains(where: \.isPending))
      }
      EchoButton("Choose a model", kind: .ghost) { store.navigate(.settings) }

    }
  }
  private var playbackClock: ReviewWordPlayback.Clock? {
    guard let player = runtime.player, player.state == .playing || player.state == .paused,
      let url = player.assetURL else { return nil }
    if player.isSimultaneous || url == runtime.sourceAudioURL { return .source }
    if url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(take.id) == .orderedSame { return .recording }
    return nil
  }
  private var playingWordID: String? {
    guard let clock = playbackClock, let player = runtime.player else { return nil }
    return ReviewWordPlayback.wordID(at: player.sourceSeconds, clock: clock,
      sentence: take.sourceSnapshot, evidence: evidence)
  }
  private var missingRecordingTiming: Bool {
    playbackClock == .recording && !take.sourceSnapshot.words.contains {
      ReviewWordPlayback.span(for: $0, clock: .recording, evidence: evidence) != nil
    }
  }
  private var transport: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 12) {
      WordFlowLayout(spacing: 12) {
        Toggle(isOn: $store.preferences.enhanceRecordings) {
          EchoLocalizedText("recording.enhance.title").font(EchoFont.metadata)
        }.toggleStyle(EchoToggleStyle())
          .help(EchoLocalization.string("recording.enhance.help", locale: locale))
          .onChange(of: store.preferences.enhanceRecordings) { stopPlayback() }
        if runtime.player?.isPreparing == true {
          EchoSpinner(size: .small)
          EchoLocalizedText("recording.enhance.preparing").font(EchoFont.metadata)
        }
      }.foregroundStyle(EchoTheme.secondaryText)
      if let player = runtime.player, player.isSimultaneous {
        ReviewComparisonTimeline(sourceElapsed: player.rangeElapsed, sourceDuration: player.rangeDuration,
          takeElapsed: player.secondElapsed, takeDuration: player.secondDuration)
      } else {
      HStack {
        EchoLocalizedText("review.playback").font(EchoFont.metadata)
        GeometryReader { proxy in
          Capsule().fill(EchoTheme.separator).overlay(alignment: .leading) {
            Capsule().fill(EchoTheme.accent).frame(width: proxy.size.width * (runtime.player?.rangeProgress ?? 0))
          }
        }.frame(height: 3).accessibilityHidden(true)
        Text(verbatim: "\(EchoFormat.time(runtime.player?.rangeElapsed ?? 0)) / \(EchoFormat.time((runtime.player?.rangeDuration ?? 0) > 0 ? runtime.player!.rangeDuration : take.duration))")
          .font(EchoFont.metadata).monospacedDigit()
      }.foregroundStyle(EchoTheme.secondaryText)
      }
      if missingRecordingTiming {
        EchoLocalizedText("review.recording_timing_missing").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { playbackButtons; Spacer(minLength: 8); recordButton }
        VStack(alignment: .leading, spacing: 10) { WordFlowLayout(spacing: 8) { playbackButtons }; recordButton }
      }
    }.padding(20).frame(maxWidth: .infinity)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
  }
  @ViewBuilder private var playbackButtons: some View {
    EchoButton("Original sentence", symbol: "speaker.wave.2", action: { coachSpeech.stop(); runtime.onPreviewOriginal() })
    EchoButton("Your full take", symbol: "play.fill", kind: runtime.player?.isSimultaneous == true ? .secondary : .primary,
      action: { coachSpeech.stop(); runtime.onPreviewTake() })
    EchoButton("A → B", symbol: "headphones", action: { coachSpeech.stop(); runtime.onCompare() })
    if let compareTogether = runtime.onCompareTogether {
      EchoButton("review.play_together", symbol: "waveform", kind: runtime.player?.isSimultaneous == true ? .primary : .secondary) {
        coachSpeech.stop(); compareTogether()
      }
    }
    EchoIconButton(symbol: "stop.fill", label: "review.stop") { stopPlayback() }
      .disabled(coachSpeech.playingAccent == nil && runtime.player?.state != .playing && runtime.player?.state != .paused && runtime.player?.state != .preparing)
  }
  private var recordButton: some View {
    EchoButton("Record sentence again", symbol: "mic") {
      stopPlayback(); recordingAgain = true; onRecordAgain()
    }
  }
  private func reviewRow(_ title: String, value: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
    EchoRowButton(minimumHeight: 32, action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
        EchoLocalizedText(title).foregroundStyle(EchoTheme.secondaryText).frame(width: 86, alignment: .leading)
        Text(verbatim: value).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(EchoTheme.secondaryText)
      }
    }
  }
  private func sound(_ key: String, _ phone: String?, color: Color = EchoTheme.text) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText(key).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      Text(verbatim: phone.map { "/\($0)/" } ?? "∅").font(EchoFont.body(size: 38)).foregroundStyle(color)
    }
  }
  private func sourceSpan(_ word: WordPronunciationEvidence, phone: PhoneDifference) -> AudioSpan? {
    if let rows = evidence?.phoneticXeus?.words.first(where: { $0.id == word.id })?.phones,
      rows.indices.contains(phone.id), let start = rows[phone.id].sourceStart, let end = rows[phone.id].sourceEnd {
      return AudioSpan(start: sourceOffset+max(0, start-0.12), end: sourceOffset+end)
    }
    if let uk = evidence?.ukReference, let rows = uk.measurements[word.id], rows.indices.contains(phone.id) {
      let span = rows[phone.id].source
      return .init(start: sourceOffset+max(0, span.start-0.18),
        end: sourceOffset+min(uk.sourceDuration, span.end+0.18))
    }
    guard let start = word.target.sourceStart, let end = word.target.sourceEnd, end > start else { return nil }
    return .init(start: start, end: end)
  }
  private func takeSpan(_ word: WordPronunciationEvidence, phone: PhoneDifference) -> AudioSpan? {
    guard let duration = evidence?.duration, let start = phone.start ?? word.phones.compactMap(\.start).min(),
      let end = phone.end ?? word.phones.compactMap(\.end).max(), end > start else { return nil }
    return .init(start: max(0, start-0.18), end: min(duration, end+0.18))
  }
  private func stopPlayback() {
    coachSpeech.stop()
    phonemeAudio.stop()
    runtime.onStop?()
  }
  private func speakExample(_ text: String) {
    runtime.onStop?()
    phonemeAudio.stop()
    coachSpeech.play(text, accent: .uk)
  }
  private func speakSound(_ ipa: String) {
    runtime.onStop?()
    coachSpeech.stop()
    phonemeAudio.play(ipa)
  }
  private func deliverySummary(_ dimension: DeliveryDimension) -> String {
    if dimension == .stress, let uk = evidence?.ukReference {
      if let word = uk.stress?.first(where: { $0.sourceSyllable != $0.takeSyllable }) {
        return word.text + " · " + EchoLocalization.format("assessment.uk.syllable_comparison", locale: locale,
          arguments: [word.sourceSyllable ?? 0, word.takeSyllable ?? 0])
      }
      if let word = uk.focus.max(by: { abs($0.takeProbability-$0.sourceProbability) < abs($1.takeProbability-$1.sourceProbability) }) {
        return word.text + " · " + copy(word.takeProbability > word.sourceProbability+0.2
          ? "assessment.uk.more_focus" : word.takeProbability < word.sourceProbability-0.2
          ? "assessment.uk.less_focus" : "assessment.uk.similar_focus")
      }
    }
    if dimension == .rhythm, let word = evidence?.ukReference?.boundaries?.max(by: {
      abs($0.takeProbability-$0.sourceProbability) < abs($1.takeProbability-$1.sourceProbability)
    }), abs(word.takeProbability-word.sourceProbability) > 0.2 {
      return word.text + " · " + copy(word.takeProbability > word.sourceProbability
        ? "assessment.uk.more_boundary" : "assessment.uk.less_boundary")
    }
    guard let delivery = evidence?.delivery, let source = delivery.source, let recorded = delivery.take else { return copy("Not assessed") }
    switch dimension {
    case .stress:
      guard let word = delivery.words.max(by: { abs($0.takeDB-$0.sourceDB) < abs($1.takeDB-$1.sourceDB) }),
        abs(word.takeDB-word.sourceDB) >= 4 else { return copy("review.delivery.compare_emphasis") }
      return EchoLocalization.format(word.takeDB < word.sourceDB ? "review.delivery.quieter_word" : "review.delivery.louder_word",
        locale: locale, arguments: [word.text])
    case .rhythm:
      return EchoLocalization.format("review.delivery.pause_summary", locale: locale, arguments: [source.pauses.count, recorded.pauses.count])
    case .intonation:
      guard let change = recorded.endingPitchChange else { return copy("review.delivery.no_pitch_short") }
      let takeEnding = copy(change > 1.5 ? "review.delivery.ending_up" : change < -1.5 ? "review.delivery.ending_down" : "review.delivery.ending_flat")
      guard let sourceChange = source.endingPitchChange else { return takeEnding }
      let sourceEnding = copy(sourceChange > 1.5 ? "review.delivery.ending_up" : sourceChange < -1.5 ? "review.delivery.ending_down" : "review.delivery.ending_flat")
      return sourceEnding + " → " + takeEnding
    case .linking:
      if let boundary = delivery.boundaries.max(by: { $0.takePause-$0.sourcePause < $1.takePause-$1.sourcePause }),
        boundary.takePause-boundary.sourcePause >= 0.18 { return boundary.phrase + " · " + copy("review.delivery.extra_pause") }
      return copy("review.delivery.compare_linking")
    }
  }
}
