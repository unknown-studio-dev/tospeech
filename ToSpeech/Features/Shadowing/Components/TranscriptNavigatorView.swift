import SwiftUI

struct TranscriptNavigatorView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var lesson: Lesson
  var contentScale: CGFloat = 1
  var selectedSentenceID: String? = nil
  /// True while the current sentence's source audio is playing, so its row
  /// indicator reads as playing instead of a static play glyph.
  var isCurrentPlaying: Bool = false
  var onSelectSentence: ((String) -> Void)? = nil
  /// Dictation supplies status-only rows. Search, tooltips and timing details
  /// must not disclose the source transcript before submission.
  var concealedStatus: ((String) -> String)? = nil
  @State private var search = ""
  @State private var following = true
  @State private var linkedText: [String: String] = [:]
  private var filtered: [LessonSentence] {
    guard concealedStatus == nil else { return lesson.sentences }
    return lesson.sentences.filter {
      search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
        || $0.translation.localizedCaseInsensitiveContains(search) || String($0.number) == search
    }
  }
  private var currentSentenceID: String? { selectedSentenceID ?? store.selectedSentenceID }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if concealedStatus == nil {
      HStack {
        Text("Trong bài này").font(EchoFont.body(size: 16 * contentScale, weight: .semibold))
        Spacer()
        Text(verbatim: EchoLocalization.format(
          "transcript.sentence_count", locale: locale, arguments: [lesson.sentences.count])).font(
          EchoFont.body(size: 11)
        ).foregroundStyle(EchoTheme.muted)
      }.frame(height: 23)
      EchoSearchField(
        placeholder: "Tìm câu tiếng Anh hoặc bản dịch…", text: $search, size: .regular)
      }
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(filtered) { sentence in
              EchoRowButton(selected: sentence.id == currentSentenceID, minimumHeight: 48 * contentScale) {
                if let onSelectSentence { onSelectSentence(sentence.id) }
                else { store.selectSentence(sentence.id) }
              } content: {
                HStack(alignment: .center, spacing: 10) {
                  Text("\(sentence.number)").font(EchoFont.body(size: 12 * contentScale))
                    .monospacedDigit().lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 20 * contentScale, alignment: .trailing)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: concealedStatus.map { EchoLocalization.string($0(sentence.id), locale: locale) } ?? linkedText[sentence.id] ?? sentence.text).font(
                      EchoFont.body(
                        size: 13 * contentScale,
                        weight: sentence.id == currentSentenceID ? .semibold : .regular)
                    ).multilineTextAlignment(.leading)
                    // Dictation hides the transcript, so its translation stays hidden too.
                    if concealedStatus == nil, !sentence.translation.isEmpty {
                      Text(verbatim: sentence.translation)
                        .font(EchoFont.body(size: 11 * contentScale))
                        .foregroundStyle(EchoTheme.secondaryText)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    }
                  }
                  Spacer(minLength: 0)
                  if concealedStatus != nil {
                    if sentence.id == currentSentenceID { Image(systemName: "pencil").foregroundStyle(EchoTheme.accent) }
                  } else if sentence.id == currentSentenceID {
                    Image(systemName: isCurrentPlaying ? "pause.fill" : "play")
                      .foregroundStyle(EchoTheme.accent)
                  } else if sentence.needsTimingReview {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(EchoTheme.caution)
                  }
                }
              }.id(sentence.id)
                .help(concealedStatus == nil ? "\(EchoFormat.time(sentence.span.start)) · \(sentence.translation)" : "")
            }
            if filtered.isEmpty {
              EchoEmptyState(title: "Không tìm thấy câu", message: "Thử từ khóa khác hoặc xóa tìm kiếm.", symbol: "magnifyingglass")
            }
          }
        }.scrollIndicators(.visible)
          .onScrollPhaseChange { _, phase in if phase == .interacting { following = false } }
          .onChange(of: currentSentenceID) { _, id in
            if following && search.isEmpty { reader.scrollTo(id, anchor: .center) }
          }
          .task {
            await Task.yield()
            reader.scrollTo(currentSentenceID, anchor: .center)
          }
        HStack {
          EchoLocalizedText(search.isEmpty ? "Cuộn để tìm câu" : EchoLocalization.format(
            "transcript.result_count", locale: locale, arguments: [filtered.count]))
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          Spacer()
          EchoButton("Về câu hiện tại") {
            search = ""
            following = true
            reader.scrollTo(currentSentenceID, anchor: .center)
          }
        }.frame(height: 32)
      }
    }
    .onChange(of: lesson.sentences, initial: true) { refreshLinking() }
    .onChange(of: store.preferences.accent) { refreshLinking() }
    .onChange(of: store.preferences.showLinking) { refreshLinking() }
    .onChange(of: search) { if !search.isEmpty { following = false } }
  }

  private func refreshLinking() {
    guard concealedStatus == nil, store.preferences.showLinking else { linkedText = [:]; return }
    linkedText = Dictionary(uniqueKeysWithValues: lesson.sentences.map { sentence in
      (sentence.id, LinkingSuggestions.markedTranscript(sentence,
        suggestions: LinkingSuggestions.suggestions(in: sentence, accent: store.preferences.accent)))
    })
  }
}
