import SwiftUI

struct LibraryCard: View {
  @Environment(\.locale) private var locale
  let lesson: Lesson
  let completed: Int
  let takeCount: Int
  let open: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      EchoMediaThumbnail(name: lesson.thumbnail, title: lesson.title,
        duration: EchoFormat.time(lesson.duration), onOpen: open, onDelete: delete)
      Text(lesson.title).font(EchoFont.heading(size: 17, weight: .medium)).lineLimit(2)
      Text(verbatim: lessonMetadata)
      .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      EchoLocalizedText(takeCount == 0 ? "Not started" : practiceMetadata)
      .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
    }
  }

  private var lessonMetadata: String {
    EchoLocalization.format(
      "lesson.accent_duration", locale: locale,
      arguments: [EchoLocalization.string(
        lesson.accent == .uk ? "British English" : "American English", locale: locale),
        EchoFormat.time(lesson.duration)])
  }

  private var practiceMetadata: String {
    EchoLocalization.format(
      "lesson.practice_counts", locale: locale, arguments: [completed, takeCount])
  }
}
