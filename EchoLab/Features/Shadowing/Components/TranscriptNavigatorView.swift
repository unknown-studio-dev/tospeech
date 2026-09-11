import SwiftUI

struct TranscriptNavigatorView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var lesson: Lesson
  var contentScale: CGFloat = 1
  var selectedSentenceID: String? = nil
  var onSelectSentence: ((String) -> Void)? = nil
  @State private var search = ""
  @State private var following = true
  private var filtered: [LessonSentence] {
    lesson.sentences.filter {
      search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
        || $0.translation.localizedCaseInsensitiveContains(search) || String($0.number) == search
    }
  }
  private var currentSentenceID: String? { selectedSentenceID ?? store.selectedSentenceID }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Trong bài này").font(EchoFont.body(size: 16 * contentScale, weight: .semibold))
        Spacer()
        Text(verbatim: EchoLocalization.format(
          "transcript.sentence_count", locale: locale, arguments: [lesson.sentences.count])).font(
          EchoFont.body(size: 11)
        ).foregroundStyle(EchoTheme.muted)
      }.frame(height: 23)
      EchoSearchField(
        placeholder: "Tìm câu tiếng Anh hoặc tiếng Việt…", text: $search, size: .regular)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(filtered) { sentence in
              EchoRowButton(selected: sentence.id == currentSentenceID, minimumHeight: 48 * contentScale) {
                if let onSelectSentence { onSelectSentence(sentence.id) }
                else { store.selectSentence(sentence.id) }
              } content: {
                HStack(alignment: .center, spacing: 10) {
                  Text("\(sentence.number)").font(EchoFont.body(size: 12 * contentScale)).frame(
                    width: 20)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(sentence.text).font(
                      EchoFont.body(
                        size: 13 * contentScale,
                        weight: sentence.id == currentSentenceID ? .semibold : .regular)
                    ).multilineTextAlignment(.leading)
                  }
                  Spacer(minLength: 0)
                  if sentence.id == currentSentenceID {
                    Image(systemName: "play").foregroundStyle(EchoTheme.accent)
                  } else if sentence.needsTimingReview {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(EchoTheme.caution)
                  }
                }
              }.id(sentence.id)
                .help("\(EchoFormat.time(sentence.span.start)) · \(sentence.translation)")
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
    }.onChange(of: search) { if !search.isEmpty { following = false } }
  }
}
