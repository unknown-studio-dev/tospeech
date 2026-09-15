import SwiftUI

struct ResumeCard: View {
  @Environment(\.locale) private var locale
  let lesson: Lesson
  let selectedSentence: LessonSentence?
  let completed: Int
  let takeCount: Int
  let open: () -> Void
  let delete: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      content(imageWidth: 224, imageHeight: 126, compact: false)
      content(imageWidth: 224, imageHeight: 126, compact: true)
    }
    .padding(20)
    .frame(minHeight: 192, alignment: .leading)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    .foregroundStyle(EchoTheme.text)
  }

  @ViewBuilder
  private func content(imageWidth: CGFloat, imageHeight: CGFloat, compact: Bool) -> some View {
    if compact {
      VStack(alignment: .leading, spacing: 16) {
        thumbnail(width: imageWidth, height: imageHeight)
        details(compact: true)
      }
    } else {
      HStack(spacing: 24) {
        thumbnail(width: imageWidth, height: imageHeight)
        details(compact: false)
      }
    }
  }

  private func thumbnail(width: CGFloat, height: CGFloat) -> some View {
    EchoMediaThumbnail(name: lesson.thumbnail, title: lesson.title,
      duration: EchoFormat.time(lesson.duration), onOpen: open, onDelete: delete)
      .frame(width: width, height: height)
  }

  @ViewBuilder private func details(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow("Pick up where you left off")
      HStack {
        Text(lesson.title).font(EchoFont.heading(size: compact ? 19 : 24)).foregroundStyle(
          EchoTheme.text
        ).lineLimit(2)
        Spacer(minLength: 10)
        if !compact { EchoButton("Tiếp tục", symbol: "arrow.right", kind: .primary, action: open) }
      }
      Text(verbatim: EchoLocalization.format(
        "resume.metadata", locale: locale,
        arguments: [selectedSentence?.number ?? min(completed + 1, lesson.sentences.count),
          lesson.sentences.count,
          EchoLocalization.string(
            lesson.accent == .uk ? "British English" : "American English", locale: locale),
          EchoFormat.time(lesson.duration)]))
      .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
      GeometryReader { geometry in
        Capsule().fill(EchoTheme.text.opacity(0.13))
          .overlay(alignment: .leading) {
            Capsule().fill(EchoTheme.success).frame(
              width:
                geometry.size.width
                * min(1, CGFloat(completed) / CGFloat(max(lesson.sentences.count, 1))))
          }
      }.frame(height: 4).padding(.top, 12)
        .accessibilityLabel(EchoLocalization.format(
          "resume.progress_accessibility", locale: locale,
          arguments: [completed, lesson.sentences.count]))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    if compact { EchoButton("Tiếp tục", symbol: "arrow.right", kind: .primary, action: open) }
  }
}
