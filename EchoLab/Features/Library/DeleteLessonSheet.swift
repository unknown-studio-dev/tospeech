import SwiftUI

struct DeleteLessonSheet: View {
  let lesson: Lesson
  let store: EchoStore

  var body: some View {
    DeleteLessonDialog(lessonTitle: lesson.title) {
      EchoThumbnail(name: lesson.thumbnail, title: lesson.title)
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    } onDelete: {
      store.deleteLesson(lesson.id)
    }
  }
}

/// Scoped D00 deletion presentation. The caller supplies the durable delete operation.
struct DeleteLessonDialog<Thumbnail: View>: View {
  let lessonTitle: String
  let thumbnail: Thumbnail
  let onDelete: () async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var isDeleting = false
  @State private var didFail = false

  init(
    lessonTitle: String,
    @ViewBuilder thumbnail: () -> Thumbnail,
    onDelete: @escaping () async -> Bool
  ) {
    self.lessonTitle = lessonTitle
    self.thumbnail = thumbnail()
    self.onDelete = onDelete
  }

  var body: some View {
    EchoDialog(
      title: "Xóa bài luyện này?", subtitle: "",
      width: 700, height: 277, close: close
    ) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 16) {
          thumbnail
          Text(verbatim: lessonTitle).font(EchoFont.body(size: 17, weight: .medium)).lineLimit(2)
        }
        Text("Xóa audio, transcript và phần chỉnh tay, bản thu cùng lịch sử của bài này trên máy.")
          .font(EchoFont.body(size: 14)).fixedSize(horizontal: false, vertical: true)
        Text("Không xóa video trên YouTube. Thao tác này không có Hoàn tác.")
          .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
        if didFail {
          EchoNotice(copy: EchoCopy("library.delete.failed"), error: true)
        }
      }
    } footer: {
      HStack {
        EchoButton("Giữ lại", kind: .secondary, size: .regular) { dismiss() }.disabled(isDeleting)
        EchoButton(
          "Xóa bài", symbol: "trash", kind: .destructive, size: .regular,
          state: isDeleting ? .loading("library.delete.deleting") : .idle
        ) { delete() }
      }
    }
  }

  private func close() {
    guard !isDeleting else { return }
    dismiss()
  }

  private func delete() {
    guard !isDeleting else { return }
    didFail = false
    isDeleting = true
    Task {
      let wasDeleted = await onDelete()
      isDeleting = false
      if wasDeleted { dismiss() } else { didFail = true }
    }
  }
}
