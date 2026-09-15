import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
  let store: EchoStore
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var title = ""
  @State private var translate = true
  @State private var captions = "Prefer creator captions"
  @State private var simulateFailure = false
  @State private var localURL: URL?
  @State private var error: String?
  var validYouTube: Bool { YouTubeLink.videoID(input) != nil }
  private func closeSheet() { dismiss() }
  var body: some View {
    EchoDialog(
      title: "Thêm video", subtitle: "Dán link YouTube để tạo bài luyện. · UI mô phỏng", width: 700,
      height: 500, close: closeSheet
    ) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          EchoTextField(
            label: "YouTube URL", text: $input, placeholder: "https://www.youtube.com/watch?v=…", size: .practice
          )
          .onChange(of: input) { _, value in if value != localURL?.path { localURL = nil } }
          EchoLocalizedText("Chỉ tải audio. Video phát online khi bạn bật; không lưu video về máy.")
            .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.muted)
        }
        VStack(alignment: .leading, spacing: 8) {
          EchoLocalizedText("Or choose local audio").font(EchoFont.body(size: 13, weight: .semibold))
          HStack {
            Group {
              if let localURL { Text(verbatim: localURL.lastPathComponent) }
              else { EchoLocalizedText("No audio file selected") }
            }.font(EchoFont.body(size: 12))
            .foregroundStyle(EchoTheme.muted)
            Spacer()
            EchoButton("Choose file", symbol: "folder", kind: .secondary) { chooseFile() }
          }
        }
        EchoTextField(label: "Lesson title (optional)", text: $title, placeholder: "Lesson title")
        EchoDisclosureGroup("Advanced preparation options") {
          VStack(alignment: .leading, spacing: 10) {
            EchoSelect(
              label: "Caption source", selection: $captions,
              options: [
                ("Prefer creator captions", "Prefer creator captions"),
                ("Automatic captions", "Automatic captions"),
                ("Audio transcript", "Audio transcript"),
              ])
            EchoCheckbox(title: "Chuẩn bị bản dịch", isOn: $translate)
            EchoCheckbox(title: "Giả lập lỗi chuẩn bị (preview)", isOn: $simulateFailure)
          }.padding(.top, 8)
        }.font(EchoFont.body(size: 12, weight: .medium))
        if let error { EchoNotice(text: error, error: true) }
      }
    } footer: {
      HStack {
        EchoLocalizedText("Nothing is uploaded in this preview.").font(EchoFont.body(size: 12)).foregroundStyle(
          EchoTheme.muted)
        Spacer()
        EchoButton("Hủy", size: .regular, action: closeSheet)
        EchoButton("Chuẩn bị bài", symbol: "arrow.down.circle", kind: .primary, size: .regular) { begin() }.disabled(
          !validYouTube && localURL == nil)
      }
    }
    .environment(\.locale, store.preferences.language.locale)
  }
  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      localURL = url
      input = url.path
      error = nil
    }
  }
  private func begin() {
    if localURL != nil {
      store.startImport(
        input: input, title: title, captions: captions, translate: translate,
        simulateFailure: simulateFailure, localFile: true)
    } else {
      store.startImport(
        input: input, title: title, captions: captions, translate: translate,
        simulateFailure: simulateFailure)
    }
    dismiss()
  }
}
