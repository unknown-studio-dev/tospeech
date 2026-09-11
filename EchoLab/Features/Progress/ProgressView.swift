import SwiftUI

struct ProgressView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  @State private var lessonID = ""
  @State private var period = "all"
  @State private var sentenceID = ""
  @State private var engine = "all"
  @State private var version = "all"
  @State private var configuration = "all"
  @State private var accent = "all"
  @State private var profilePresented = false
  @State private var search = ""

  private var lesson: Lesson? { store.lessons.first { $0.id == lessonID } }
  private var takes: [PracticeTake] {
    store.takes.filter {
      $0.lessonID == lessonID
        && (period == "all"
          || $0.createdAt >= Date().addingTimeInterval(period == "7" ? -604800 : -2_592_000))
    }
  }
  private var assessments: [AssessmentResult] { takes.flatMap(\.assessments) }
  private var sentenceOptions: [(id: String, title: String)] {
    lesson?.sentences.map { (id: $0.id, title: "\($0.number) · \($0.text)") } ?? []
  }
  private var filtered: [PracticeTake] {
    let q = search.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return takes.filter { take in
      (sentenceID == "all" || take.sentenceID == sentenceID)
        && (q.isEmpty || take.sourceSnapshot.text.lowercased().contains(q))
        && (engine == "all" || take.assessments.contains { matches($0) })
    }.sorted { $0.createdAt > $1.createdAt }
  }
  private var concrete: Bool {
    engine != "all" && version != "all" && configuration != "all" && accent != "all"
  }
  private func matches(_ result: AssessmentResult) -> Bool {
    (engine == "all" || result.engine.rawValue == engine)
      && (version == "all" || result.version == version)
      && (configuration == "all" || result.configuration == configuration)
      && (accent == "all" || result.accent.rawValue == accent)
  }
  private func result(for take: PracticeTake) -> AssessmentResult? {
    take.assessments.reversed().first { matches($0) && $0.status == .complete && $0.score != nil }
  }
  private var comparable: [PracticeTake] {
    guard let sentence = lesson?.sentences.first(where: { $0.id == sentenceID }), concrete else {
      return []
    }
    return takes.filter {
      $0.sentenceID == sentence.id && $0.scope == .sentence
        && $0.sourceSnapshot.revision == sentence.revision && result(for: $0) != nil
    }.sorted { $0.createdAt < $1.createdAt }
  }
  private var allScoreTakes: [PracticeTake] { comparable }

  var body: some View {
    GeometryReader { _ in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if store.lessons.isEmpty {
            EchoPanel {
              EchoEmptyState(
                title: "Progress starts with your first lesson",
                message: "Import a lesson and record a sentence to see honest history here.",
                symbol: "chart.bar.xaxis")
            }
            returnView
          } else {
            videoBar
            stats
            analysis
            history
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(EchoTheme.canvas)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        EchoSelect(
          label: "Date range", selection: $period,
          options: [("all", "All time"), ("30", "Last 30 days"), ("7", "Last 7 days")]
        ).frame(width: 150)
        EchoButton("Continue", symbol: "play.fill", kind: .primary) {
          if let id = lessonID.nonEmpty { store.openLesson(id) }
        }
      }
    }
    .onAppear {
      if lessonID.isEmpty { lessonID = store.selectedLessonID ?? store.lessons.first?.id ?? "" }
      if sentenceID.isEmpty { resetFilters() }
    }
  }
  private var returnView: some View {
    EchoButton("Go to Library", symbol: "books.vertical", kind: .secondary) {
      store.navigate(.library)
    }
  }
  private var videoBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { videoBarContent }
      VStack(alignment: .leading, spacing: 12) { videoBarContent }
    }
    .padding(12)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 13))
  }

  @ViewBuilder private var videoBarContent: some View {
    EchoThumbnail(
      name: lesson?.thumbnail ?? "conversation", title: lesson?.title ?? "Selected video"
    ).frame(width: 86, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
    VStack(alignment: .leading, spacing: 4) {
      Group {
        if let lesson { Text(verbatim: lesson.title) }
        else { EchoLocalizedText("Choose a video") }
      }.font(EchoFont.body(size: 16, weight: .semibold))
      Text(verbatim: EchoLocalization.format(
        "progress.lesson_metadata", locale: locale,
        arguments: [EchoLocalization.string(
          lesson?.accent == .uk ? "British English" : "American English", locale: locale),
          EchoFormat.time(lesson?.duration ?? 0)]))
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
    }
    Spacer()
    EchoSelect(
      label: "Change video", selection: $lessonID,
      options: store.lessons.map { ($0.id, $0.title) }
    ).frame(maxWidth: 240).onChange(of: lessonID) { _, _ in resetFilters() }
  }
  private var stats: some View {
    let minutes = takes.reduce(0) { $0 + $1.duration } / 60
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { statItems(minutes: minutes) }
      VStack(spacing: 12) { statItems(minutes: minutes) }
    }
  }

  @ViewBuilder private func statItems(minutes: Double) -> some View {
    stat(
      "Practice time",
      minutes == 0 ? "—" : minutes < 1
        ? EchoLocalization.string("progress.less_than_minute", locale: locale)
        : EchoLocalization.format(
          "progress.minutes", locale: locale, arguments: [Int(minutes.rounded())]),
      takes.isEmpty
        ? "No saved takes yet"
        : EchoLocalization.format(
          "progress.practice_sessions", locale: locale,
          arguments: [Set(takes.map { Calendar.current.startOfDay(for: $0.createdAt) }).count])
    )
    stat(
      "Sentences practiced",
      "\(Set(takes.map(\.sentenceID)).count) / \(lesson?.sentences.count ?? 0)",
      "Sentences practiced in this video")
    stat(
      "Saved recordings", takes.isEmpty ? "—" : EchoLocalization.format(
        "progress.take_count", locale: locale, arguments: [takes.count]),
      "Includes unscored and recovery states")
  }
  private func stat(_ label: String, _ value: String, _ note: String) -> some View {
    EchoPanel(padding: 20, verticalPadding: 12) {
      VStack(alignment: .leading, spacing: 5) {
        EchoLocalizedText(label).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
        Text(value).font(EchoFont.heading(size: 26, weight: .medium))
        EchoLocalizedText(note).font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
      }.frame(height: 72, alignment: .leading)
    }
  }
  private var analysis: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 24) {
        analysisChart
        comparisonCard
      }
      VStack(alignment: .leading, spacing: 16) {
        analysisChart
        comparisonCard.frame(maxWidth: .infinity)
      }
    }
  }

  private var analysisChart: some View {
    EchoPanel(padding: 20) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Your progress on this video").font(EchoFont.heading(size: 17, weight: .medium))
          Spacer()
          EchoLocalizedText(concrete ? EchoLocalization.format(
            "progress.matched_sentence", locale: locale,
            arguments: [accent.uppercased()]) : "Choose a profile")
            .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
        }
        if concrete && !allScoreTakes.isEmpty {
          HStack(alignment: .bottom, spacing: 20) {
            ForEach(Array(allScoreTakes.suffix(5))) { take in
              if let score = result(for: take)?.score {
                VStack(spacing: 5) {
                  Text(EchoFormat.decimal(score)).font(EchoFont.body(size: 13, weight: .semibold))
                  RoundedRectangle(cornerRadius: 5).fill(EchoTheme.success).frame(
                    width: 48, height: max(12, score * 1.05))
                  Text(take.createdAt.formatted(
                    .dateTime.month(.abbreviated).day().locale(locale))).font(
                    EchoFont.body(size: 10)
                  ).foregroundStyle(EchoTheme.muted)
                }
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 138, alignment: .bottom)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            EchoLocalizedText(concrete ? "No comparable scores yet" : "No score trend shown")
              .font(EchoFont.heading(size: 18))
            Text(
              "Choose a sentence and one assessment profile. Different revisions and practice scopes are not mixed."
            )
            .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
            EchoButton("Choose comparison profile", kind: .ghost) { profilePresented = true }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        Text("Same engine, version, configuration, accent and sentence revision.")
          .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
      }.frame(height: 190, alignment: .top)
    }.frame(maxWidth: .infinity)
  }
  private var comparisonCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("First → latest · matched sentences").font(EchoFont.heading(size: 17, weight: .medium))
      Text("Compare compatible takes of the selected sentence.")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      HStack {
        Text("Overall score").font(EchoFont.body(size: 13))
        Spacer()
        Text(scoreChange).font(EchoFont.heading(size: 22, weight: .medium))
      }
      Text("Delivery detail is available inside each saved assessment.")
        .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
      Spacer()
      HStack {
        EchoButton("First take", kind: .secondary) { openComparable(first: true) }.disabled(
          comparable.isEmpty)
        EchoButton("Latest take", kind: .primary) { openComparable(first: false) }.disabled(
          comparable.isEmpty)
      }
    }
    .padding(20).frame(minWidth: 280, idealWidth: 432, maxWidth: .infinity, minHeight: 230)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
  }
  private var scoreChange: String {
    guard let first = comparable.first, let latest = comparable.last,
      let a = result(for: first)?.score, let b = result(for: latest)?.score
    else { return "— → —" }
    return "\(Int(a.rounded())) → \(Int(b.rounded()))"
  }
  private var history: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("All recordings").font(EchoFont.heading(size: 17, weight: .medium))
        Spacer()
        Text(verbatim: EchoLocalization.format(
          "progress.shown", locale: locale, arguments: [filtered.count])).font(EchoFont.body(size: 11)).foregroundStyle(
          EchoTheme.muted)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { historyFilters }
        VStack(alignment: .leading, spacing: 10) { historyFilters }
      }
      if filtered.isEmpty {
        EchoEmptyState(
          title: "No takes match these filters",
          message:
            "Unscored takes are retained, but only completed compatible assessments appear in trends.",
          symbol: "line.3.horizontal.decrease.circle")
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(filtered) { take in
              ProgressTakeRow(take: take, result: result(for: take)) {
                store.openLesson(take.lessonID, sentenceID: take.sentenceID, takeID: take.id)
              }
            }
          }.padding(1)
        }.frame(height: min(300, CGFloat(filtered.count * 56)))
      }
    }
  }

  @ViewBuilder private var historyFilters: some View {
    EchoSearchField(placeholder: "Search a sentence", text: $search).frame(maxWidth: 330)
    EchoSelect(
      label: "Sentence", selection: $sentenceID,
      options: [("all", "All sentences")] + sentenceOptions
    ).frame(maxWidth: 400)
    EchoButton("Comparison profile", symbol: "slider.horizontal.3") { profilePresented = true }
      .popover(isPresented: $profilePresented) { profileFilters }
    Spacer(minLength: 0)
  }
  private var profileFilters: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Comparison profile").font(EchoFont.heading(size: 18, weight: .medium))
      Text("Choose one sentence in the list to compare its takes.")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      EchoSelect(label: "Engine", selection: $engine, options: engineOptions)
        .onChange(of: engine) {
          version = "all"
          configuration = "all"
        }
      EchoSelect(label: "Version", selection: $version, options: versionOptions)
        .disabled(engine == "all").onChange(of: version) { configuration = "all" }
      EchoSelect(label: "Configuration", selection: $configuration, options: configOptions)
        .disabled(engine == "all" || version == "all")
      EchoSelect(
        label: "Accent", selection: $accent,
        options: [
          ("all", "All accents"), (ReferenceAccent.uk.rawValue, "British English"),
          (ReferenceAccent.us.rawValue, "American English"),
        ])
      HStack {
        EchoButton("Clear filters") {
          sentenceID = "all"
          engine = "all"
          version = "all"
          configuration = "all"
          accent = "all"
        }
        Spacer()
        EchoButton("Done", kind: .primary) { profilePresented = false }
      }
    }.padding(20).frame(width: 390)
  }
  private var engineOptions: [(id: String, title: String)] {
    [("all", "All engines")]
      + Array(Set(assessments.map { $0.engine })).sorted { $0.rawValue < $1.rawValue }.map {
        ($0.rawValue, $0.title)
      }
  }
  private var versionOptions: [(id: String, title: String)] {
    [("all", "All versions")]
      + Array(
        Set(assessments.filter { engine == "all" || $0.engine.rawValue == engine }.map(\.version))
      ).sorted().map { ($0, $0) }
  }
  private var configOptions: [(id: String, title: String)] {
    [("all", "All configurations")]
      + Array(
        Set(
          assessments.filter {
            (engine == "all" || $0.engine.rawValue == engine)
              && (version == "all" || $0.version == version)
          }.map(\.configuration))
      ).sorted().map { ($0, $0) }
  }
  private func resetFilters() {
    sentenceID = "all"
    engine = "all"
    version = "all"
    configuration = "all"
    accent = "all"
    search = ""
    if let take = takes.sorted(by: { $0.createdAt > $1.createdAt }).first(where: { take in
      take.scope == .sentence
        && lesson?.sentences.contains(where: {
          $0.id == take.sentenceID && $0.revision == take.sourceSnapshot.revision
        }) == true
        && take.assessments.contains(where: { $0.status == .complete && $0.score != nil })
    }), let assessment = take.assessments.last(where: { $0.status == .complete && $0.score != nil })
    {
      sentenceID = take.sentenceID
      engine = assessment.engine.rawValue
      version = assessment.version
      configuration = assessment.configuration
      accent = assessment.accent.rawValue
    }
  }
  private func openComparable(first: Bool) {
    guard let target = (first ? comparable.first : comparable.last) else { return }
    store.openLesson(target.lessonID, sentenceID: target.sentenceID, takeID: target.id)
  }
}

extension String { fileprivate var nonEmpty: String? { isEmpty ? nil : self } }
