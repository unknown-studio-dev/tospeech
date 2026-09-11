import SwiftUI

/// All primary transcription models share the existing model-list card and actions.
struct TranscriptionModelsSection: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  @Environment(\.whisperModelManager) private var manager
  @Environment(\.parakeetModelManager) private var parakeet
  @State private var expanded: String?
  @State private var removeCandidate: WhisperModelVariant?

  var body: some View {
    if let manager {
      content(manager)
        .sheet(item: $removeCandidate) { variant in
          EchoDialog(title: "Xóa gói model?", subtitle: "", width: 520, height: 210,
            close: { removeCandidate = nil }) {
            VStack(alignment: .leading, spacing: 12) {
              Text(verbatim: "Whisper " + variant.displayName).font(EchoFont.body(size: 16, weight: .semibold))
              EchoLocalizedText("Bản thu và các kết quả đánh giá trước đây vẫn được giữ lại.")
                .fixedSize(horizontal: false, vertical: true)
            }
          } footer: {
            HStack {
              EchoButton("Giữ lại", size: .regular) { removeCandidate = nil }
              EchoButton("settings.model.remove", kind: .destructive, size: .regular) {
                removeCandidate = nil
                Task { await manager.remove(variant) }
              }
            }
          }
        }
    }
  }

  @ViewBuilder
  private func content(_ manager: WhisperModelManager) -> some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 16) {
      EchoLocalizedText("settings.model.title")
        .font(EchoFont.heading(size: 20, weight: .semibold))
      EchoLocalizedText("settings.model.subtitle")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      if let error = manager.error {
        EchoNotice(copy: EchoCopy("storage.detail", arguments: [.raw(error)]), error: true)
      }
      if let parakeet {
        if let failure = parakeet.failure { EchoNotice(copy: EchoCopy(failure), error: true) }
        parakeetCard(parakeet)
      }
      ForEach(manager.states(active: store.preferences.activeTranscriptionModel)) { state in
        card(state, manager: manager)
      }
    }
    .task { await manager.refresh() }
  }

  private func parakeetCard(_ manager: ParakeetModelManager) -> some View {
    let isExpanded = expanded == "parakeet"
    return ModelCardView(
      title: "Parakeet TDT 0.6B v3",
      statusLine: label(manager.isInstalling ? "transcription.parakeet.installing"
        : manager.isInstalled ? "settings.model.status.installed" : "settings.model.status.not_installed"),
      isActive: manager.isInstalled && store.preferences.transcriptionEngine == "parakeet",
      activeLabel: label("settings.model.in_use")
    ) {
      EchoButton(label(isExpanded ? "settings.model.details.hide" : "settings.model.details.show"),
        kind: .ghost, size: .regular) {
          expanded = isExpanded ? nil : "parakeet"
        }
      if manager.isInstalling {
        EchoButton(label("settings.model.downloading_button"), size: .regular) {}.disabled(true)
      } else if manager.isInstalled {
        if store.preferences.transcriptionEngine != "parakeet" {
          EchoButton(label("settings.model.activate"), kind: .primary, size: .regular) {
            store.preferences.transcriptionEngine = "parakeet"
          }
        }
      } else {
        EchoButton(label(manager.failure == nil ? "settings.model.download" : "settings.model.retry"),
          symbol: "arrow.down.circle", size: .regular) {
            Task { await manager.install() }
          }
      }
    } footer: {
      if isExpanded {
        VStack(alignment: .leading, spacing: 6) {
          EchoLocalizedText("settings.model.details.ondevice")
          EchoLocalizedText("transcription.parakeet.details")
        }
        .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .task { await manager.refresh() }
  }

  @ViewBuilder
  private func card(_ state: TranscriptionModelState, manager: WhisperModelManager) -> some View {
    let key = state.variant.whisperKitModel
    let downloading = state.status == "downloading" || state.status == "verifying"
    let isExpanded = expanded == state.variant.rawValue
    ModelCardView(
      title: "Whisper " + state.variant.displayName,
      statusLine: meta(state, manager),
      isActive: state.isActive && store.preferences.transcriptionEngine == "whisper",
      activeLabel: label("settings.model.in_use"),
      progressFraction: downloading ? (manager.progress[key] ?? 0) : nil,
      progressTitle: label("settings.model.progress_title")
    ) {
      EchoButton(
        label(isExpanded ? "settings.model.details.hide" : "settings.model.details.show"),
        kind: .ghost, size: .regular
      ) {
        expanded = isExpanded ? nil : state.variant.rawValue
      }
      actions(state, manager: manager)
    } footer: {
      if isExpanded { details(state.variant) }
    }
  }

  @ViewBuilder
  private func actions(_ state: TranscriptionModelState, manager: WhisperModelManager) -> some View
  {
    @Bindable var store = store
    let variant = state.variant
    switch state.status {
    case "installed":
      if !state.isActive || store.preferences.transcriptionEngine != "whisper" {
        EchoButton(label("settings.model.activate"), kind: .primary, size: .regular) {
          store.preferences.activeTranscriptionModel = variant.rawValue
          store.preferences.transcriptionEngine = "whisper"
        }
      }
      EchoIconButton(
        symbol: "trash",
        label: state.isActive ? "settings.model.remove_disabled" : "settings.model.remove",
        size: .regular
      ) {
        removeCandidate = variant
      }.disabled(state.isActive)
    case "downloading", "verifying":
      EchoButton(label("settings.model.downloading_button"), size: .regular) {}.disabled(true)
    case "failed":
      EchoButton(label("settings.model.retry"), size: .regular) {
        Task { await manager.install(variant) }
      }
    default:
      EchoButton(label("settings.model.download"), symbol: "arrow.down.circle", size: .regular) {
        Task { await manager.install(variant) }
      }
    }
  }

  @ViewBuilder
  private func details(_ variant: WhisperModelVariant) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText("settings.model.details.ondevice")
      EchoLocalizedText("settings.model.details.accents")
      Text(
        verbatim: EchoLocalization.format(
          "settings.model.details.size", locale: locale,
          arguments: [Int(variant.approximateDownloadBytes / 1_000_000)]))
    }
    .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func label(_ key: String) -> String {
    EchoLocalization.string(key, locale: locale)
  }

  private func meta(_ state: TranscriptionModelState, _ manager: WhisperModelManager) -> String {
    let megabytes = Int(state.variant.approximateDownloadBytes / 1_000_000)
    return EchoLocalization.format(
      "settings.model.meta", locale: locale, arguments: [megabytes, status(state, manager)])
  }

  private func status(_ state: TranscriptionModelState, _ manager: WhisperModelManager) -> String {
    switch state.status {
    case "installed": label("settings.model.status.installed")
    case "downloading", "verifying":
      EchoLocalization.format(
        "settings.model.status.downloading", locale: locale,
        arguments: [Int((manager.progress[state.variant.whisperKitModel] ?? 0) * 100)])
    case "failed": label("settings.model.status.failed")
    default: label("settings.model.status.not_installed")
    }
  }
}
