import Speech
import SwiftUI

struct AppleSpeechTranscriptionSection: View {
  @Environment(EchoStore.self) private var store
  @State private var status: String = "speech.model.checking"
  @State private var failure: EchoCopy?
  @State private var isInstalling = false
  private var localeIdentifier: String { store.preferences.accent == .uk ? "en-GB" : "en-US" }

  var body: some View {
    @Bindable var store = store
    SettingsSection(title: "speech.model.title", subtitle: "speech.model.description", titleSize: 16) {
      VStack(alignment: .leading, spacing: 12) {
        EchoCheckbox(title: "transcription.apple.compare", isOn: $store.preferences.compareTranscriptWithApple)
        Text(verbatim: "Apple SpeechTranscriber").font(EchoFont.body(size: 16, weight: .semibold))
        EchoLocalizedText("speech.model.local").font(EchoFont.body(size: 13))
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          EchoLocalizedText(localeIdentifier == "en-GB" ? "speech.model.uk" : "speech.model.us")
          Spacer()
          EchoLocalizedText(status).foregroundStyle(EchoTheme.muted)
        }.font(EchoFont.body(size: 13))
        if let failure { EchoNotice(copy: failure, error: true) }
        EchoButton("speech.model.prepare", symbol: "arrow.down.circle", kind: .secondary) {
          Task { await prepare() }
        }.disabled(isInstalling || status == "speech.model.installed")
      }
    }
    .task(id: localeIdentifier) { await refresh() }
  }

  private func refresh() async {
    let locale = localeIdentifier
    do {
      let module = try await AppleSpeechAnalyzerTranscriber.module(localeIdentifier: locale)
      let installed = await AssetInventory.status(forModules: [module]) == .installed
      guard localeIdentifier == locale else { return }
      status = installed ? "speech.model.installed" : "speech.model.download_needed"
      failure = nil
    } catch {
      guard localeIdentifier == locale else { return }
      status = "speech.model.unavailable"
      failure = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }

  private func prepare() async {
    guard !isInstalling else { return }
    isInstalling = true
    failure = nil
    status = "speech.model.downloading"
    defer { isInstalling = false }
    do {
      let module = try await AppleSpeechAnalyzerTranscriber.module(localeIdentifier: localeIdentifier)
      try await AppleSpeechAnalyzerTranscriber.installAssets(for: module)
      await refresh()
    } catch {
      status = "speech.model.unavailable"
      failure = EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
    }
  }
}
