import SwiftUI

struct ProductionLibraryView: View {
  @Environment(EchoStore.self) private var store
  @Bindable var model: ProductionLibraryModel
  let startPracticing: (LibraryLessonSummary) -> Void
  @State private var search = ""
  @State private var showImport = false
  @State private var submittedImportJob: ProductionImportJob?
  @State private var lessonToDelete: LibraryLessonSummary?

  private var visibleLessons: [LibraryLessonSummary] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let readyLessons = model.lessons.filter { $0.lifecycle == .ready }
    return query.isEmpty
      ? readyLessons
      : readyLessons.filter {
        $0.title.lowercased().contains(query) || ($0.author?.lowercased().contains(query) ?? false)
      }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Mỗi ngày, một chút tốt hơn.").font(EchoFont.heading(size: 28))
        ForEach(model.jobs) { job in
          ProductionImportJobBanner(job: job) {
            model.showImportStatus(for: job)
          } cancel: {
            Task { await model.cancel(job) }
          } retry: {
            Task { await model.retry(job) }
          } retryUsingCurrentEngine: {
            Task { await model.retryUsingSettings(job, preferences: store.preferences) }
          }
        }
        if model.failedDeletionID != nil {
          EchoPanel {
            HStack(spacing: 16) {
              Image(systemName: "trash.slash").foregroundStyle(EchoTheme.danger)
              Text("Deletion did not finish. The saved intent will be retried safely.")
                .font(EchoFont.body(size: 12))
              Spacer()
              EchoButton("Retry deletion", symbol: "arrow.clockwise", kind: .secondary) {
                Task { await model.retryDeletion() }
              }
            }
          }
        }
        HStack {
          Text("Bài luyện của bạn").font(EchoFont.heading(size: 20, weight: .medium))
          Spacer()
          EchoSearchField(placeholder: "Tìm bài luyện…", text: $search).frame(width: 310)
        }
        if model.isLoading {
          ProgressView().frame(maxWidth: .infinity, minHeight: 180)
        } else if visibleLessons.isEmpty {
          EchoPanel {
            EchoEmptyState(
              title: "Your library is ready when you are",
              message: "Import a YouTube lesson or choose a local audio file.",
              symbol: "books.vertical")
          }
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24)], spacing: 28) {
            ForEach(visibleLessons) { lesson in
              ProductionLibraryCard(lesson: lesson) {
                lessonToDelete = lesson
              } startPracticing: {
                startPracticing(lesson)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(
      isPresented: $showImport,
      onDismiss: {
        guard let job = submittedImportJob else { return }
        submittedImportJob = nil
        model.showImportStatus(for: job)
      }
    ) {
      ProductionImportSheet(model: model) { job in
        submittedImportJob = job
        showImport = false
      }
    }
    .sheet(item: $lessonToDelete) { lesson in
      DeleteLessonDialog(lessonTitle: lesson.title) {
        ProductionLessonThumbnail(lesson: lesson)
          .frame(width: 112, height: 63)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } onDelete: {
        await model.delete(lesson)
      }
    }
    .sheet(item: $model.importPresentation) { context in
      ImportPreparationSheet(
        presentation: context.presentation,
        onDismiss: { model.dismissImportPresentation(jobID: context.jobID) },
        onCancelImport: { Task { await model.cancel(jobID: context.jobID) } },
        onStartPracticing: {
          guard let lesson = model.lessons.first(where: { $0.id == context.lessonID }) else {
            model.dismissImportPresentation(jobID: context.jobID)
            return
          }
          model.dismissImportPresentation(jobID: context.jobID)
          startPracticing(lesson)
        })
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        EchoButton("Thêm video", symbol: "plus", kind: .primary, size: .regular) {
          showImport = true
        }
      }
    }
    .task { await model.load() }
    .overlay(alignment: .bottom) {
      if let error = model.error { EchoNotice(copy: error, error: true).padding(24) }
    }
  }
}

private struct ProductionLibraryCard: View {
  let lesson: LibraryLessonSummary
  let delete: () -> Void
  let startPracticing: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .topTrailing) {
        ProductionLessonThumbnail(lesson: lesson)
          .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipShape(
            RoundedRectangle(cornerRadius: 12))
        EchoIconButton(
          symbol: "trash", label: "Delete lesson: \(lesson.title)", dark: true, action: delete
        ).padding(8)
      }
      Text(lesson.title).font(EchoFont.heading(size: 17, weight: .medium)).lineLimit(2)
      Text(lesson.duration.map(EchoFormat.time) ?? "Audio unavailable")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      if lesson.lifecycle == .ready {
        Text(
          lesson.isPracticeReady
            ? "\(lesson.preparedSentenceCount) prepared sentences"
            : "Lesson preparation needs a transcript and sentence timing."
        )
        .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
      }
      if lesson.lifecycle == .ready {
        EchoButton("Start", symbol: "play.fill", kind: .primary, action: startPracticing)
          .disabled(!lesson.isPracticeReady)
          .echoHelp(
            lesson.isPracticeReady
              ? "Start practicing this prepared lesson."
              : "Lesson preparation needs a transcript and sentence timing.")
      }
    }
  }
}

private struct ProductionLessonThumbnail: View {
  let lesson: LibraryLessonSummary

  var body: some View {
    AsyncImage(url: lesson.thumbnailURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Rectangle().fill(EchoTheme.soft).overlay(
        Image(systemName: "waveform").foregroundStyle(EchoTheme.muted))
    }
    .clipped()
    .accessibilityLabel(Text(verbatim: lesson.title))
  }
}
