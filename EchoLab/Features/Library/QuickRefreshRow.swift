import SwiftUI

struct QuickRefreshRow: View {
  let count: Int
  @Environment(EchoStore.self) private var store

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        copy
        Spacer()
        action
      }
      VStack(alignment: .leading, spacing: 12) {
        copy
        action
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 16)
    .frame(minHeight: 81, alignment: .leading)
    .background(EchoTheme.selected, in: RoundedRectangle(cornerRadius: 14))
  }

  private var copy: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Những từ muốn luyện lại").font(EchoFont.body(size: 15, weight: .semibold))
      Text("Quay lại các đoạn cần cải thiện trong bài đang học.")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
    }
  }

  private var action: some View {
    EchoButton("Review sentences", symbol: "arrow.counterclockwise", kind: .secondary) {
      if let take = store.takes.first(where: { [.complete, .earlyStop].contains($0.outcome) }) {
        store.openLesson(take.lessonID, sentenceID: take.sentenceID, takeID: take.id)
      }
    }
  }
}
