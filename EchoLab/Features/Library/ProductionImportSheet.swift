import SwiftUI
import UniformTypeIdentifiers

struct ProductionImportSheet: View {
  @Bindable var model: ProductionLibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection = ProductionImportSelection()
  @State private var title = ""
  @State private var choosingFile = false

  private var youtubeURL: URL? { selection.youtubeURL }

  var body: some View {
    EchoDialog(title: "Thêm video", subtitle: "Chỉ tải audio; không lưu video về máy.", width: 620, height: 380, close: { dismiss() }) {
      VStack(alignment: .leading, spacing: 16) {
        EchoTextField(label: "YouTube URL", text: $selection.youtubeInput, placeholder: "https://www.youtube.com/watch?v=…")
          .onChange(of: selection.youtubeInput) { _, value in selection.updateYouTubeInput(value) }
        HStack {
          Text(selection.localURL?.lastPathComponent ?? "No audio file selected").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
          Spacer()
          EchoButton("Choose file", symbol: "folder", kind: .secondary) { choosingFile = true }
        }
        EchoTextField(label: "Lesson title (optional)", text: $title, placeholder: "Lesson title")
      }
        if let error = model.error { EchoNotice(copy: error, error: true) }
    } footer: {
      HStack {
        Spacer()
        EchoButton("Hủy", kind: .secondary) { dismiss() }
        EchoButton("Chuẩn bị bài", symbol: "arrow.down.circle", kind: .primary) {
          let request: ProductionImportRequest? = selection.localURL.map { .localAudio(url: $0, securityScoped: true, titleOverride: title.nonBlank) }
            ?? youtubeURL.map { .youtube(url: $0, titleOverride: title.nonBlank) }
          guard let request else { return }
          Task { if await model.submit(request) != nil { dismiss() } }
        }
        .disabled(selection.localURL == nil && youtubeURL == nil)
      }
    }
    .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
      switch result {
      case .success(let url): selection.chooseLocalFile(url)
      case .failure(let failure):
        model.error = EchoCopy("storage.detail", arguments: [.raw(failure.localizedDescription)])
      }
    }
  }
}

struct ProductionImportSelection: Equatable {
  var youtubeInput = ""
  private(set) var localURL: URL?

  var youtubeURL: URL? {
    let value = youtubeInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard YouTubeLink.videoID(value) != nil else { return nil }
    return URL(string: value)
  }

  mutating func updateYouTubeInput(_ value: String) {
    youtubeInput = value
    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { localURL = nil }
  }

  mutating func chooseLocalFile(_ url: URL) {
    localURL = url
    youtubeInput = ""
  }
}

private extension String { var nonBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }
