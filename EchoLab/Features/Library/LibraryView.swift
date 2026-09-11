import SwiftUI

struct LibraryView: View {
  @Environment(EchoStore.self) private var store
  @State private var search = ""
  @State private var showImport = false
  @State private var lessonToDelete: Lesson?

  private var visibleLessons: [Lesson] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return store.lessons.filter { $0.id != resumeLesson?.id } }
    return store.lessons.filter {
      $0.title.lowercased().contains(query) || $0.author.lowercased().contains(query)
    }
  }
  private var resumeLesson: Lesson? { store.selectedLesson ?? store.lessons.first }
  private func takeCount(for lesson: Lesson) -> Int {
    store.takes.filter { $0.lessonID == lesson.id }.count
  }
  private func completed(for lesson: Lesson) -> Int {
    Set(
      store.takes.filter {
        $0.lessonID == lesson.id && $0.scope == .sentence
          && [.complete, .earlyStop].contains($0.outcome)
      }.map(\.sentenceID)
    ).count
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollView {
        let contentWidth = max(0, viewport.size.width)
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
              Text("Mỗi ngày, một chút tốt hơn.").font(
                EchoFont.heading(size: viewport.size.width < 700 ? 24 : 28))
            }
            Spacer()
          }.frame(minHeight: 34)
          if let job = store.importJob, job.phase != .cancelled {
            ImportJobBanner(job: job, store: store)
          }
          if let lesson = resumeLesson, !store.lessons.isEmpty {
            ResumeCard(
              lesson: lesson, selectedSentence: store.selectedSentence,
              completed: completed(for: lesson), takeCount: takeCount(for: lesson),
              open: { store.openLesson(lesson.id) }, delete: { lessonToDelete = lesson })
          }
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
              Text("Bài luyện của bạn").font(EchoFont.heading(size: 20, weight: .medium))
            }
            Spacer()
            EchoSearchField(placeholder: "Tìm bài luyện…", text: $search)
              .frame(width: min(310, max(210, contentWidth * 0.32)))
          }.padding(.bottom, 0)
          if store.lessons.isEmpty {
            EchoPanel {
              EchoEmptyState(
                title: "Your library is ready when you are",
                message:
                  "Import a YouTube lesson or choose a local audio file. No demo content is added here.",
                symbol: "books.vertical")
            }
          } else if visibleLessons.isEmpty {
            EchoPanel {
              EchoEmptyState(
                title: "No matching lessons", message: "Try another title or clear the search.",
                symbol: "magnifyingglass")
            }
          } else {
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 24),
                count: columnCount(for: contentWidth)), spacing: 28
            ) {
              ForEach(visibleLessons) { lesson in
                LibraryCard(
                  lesson: lesson, completed: completed(for: lesson),
                  takeCount: takeCount(for: lesson), open: { store.openLesson(lesson.id) },
                  delete: { lessonToDelete = lesson })
              }
            }
          }
          if !store.takes.isEmpty {
            QuickRefreshRow(
              count: min(
                3, store.takes.filter { [.complete, .earlyStop].contains($0.outcome) }.count))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(EchoTheme.canvas).sheet(isPresented: $showImport) { ImportSheet(store: store) }
    .sheet(item: $lessonToDelete) { lesson in DeleteLessonSheet(lesson: lesson, store: store) }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        EchoButton("Thêm video", symbol: "plus", kind: .primary, size: .regular) {
          showImport = true
        }
      }
    }
  }

  private func columnCount(for width: CGFloat) -> Int {
    if width < 752 { return 1 }
    if width < 1032 { return 2 }
    if width < 1552 { return 3 }
    return 4
  }
}
