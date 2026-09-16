import SwiftUI

/// Parakeet is the only primary transcription engine; word alignment backs its word-level timing
/// for every accent. Both cards reuse the shared model-list chrome.
struct TranscriptionModelsSection: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  @Environment(\.parakeetModelManager) private var parakeet
  @Environment(\.alignmentModelManager) private var alignment
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      EchoLocalizedText("settings.model.title")
        .font(EchoFont.heading(size: 20, weight: .semibold))
      EchoLocalizedText("settings.model.subtitle")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      if let parakeet {
        if let failure = parakeet.failure { EchoNotice(copy: EchoCopy(failure), error: true) }
        parakeetCard(parakeet)
      }
      if let alignment {
        if let failure = alignment.failure { EchoNotice(copy: EchoCopy(failure), error: true) }
        alignmentCard(alignment)
      }
    }
  }

  private func parakeetCard(_ manager: ParakeetModelManager) -> some View {
    ModelCardView(
      title: "Parakeet TDT 0.6B v3",
      statusLine: label(manager.isInstalling ? "transcription.parakeet.installing"
        : manager.isInstalled ? "settings.model.status.installed" : "settings.model.status.not_installed"),
      isActive: manager.isInstalled && store.preferences.transcriptionEngine == "parakeet",
      activeLabel: label("settings.model.in_use")
    ) {
      EchoButton(label(expanded ? "settings.model.details.hide" : "settings.model.details.show"),
        kind: .ghost, size: .regular) {
          expanded.toggle()
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
      if expanded {
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

  /// Word alignment backs word-level timing for every practice session, not a selectable
  /// transcription engine, so this card has no activate/switch control — only install/retry.
  private func alignmentCard(_ manager: AlignmentModelManager) -> some View {
    ModelCardView(
      title: "Word Alignment · CTC",
      statusLine: label(manager.isInstalling ? "transcription.alignment.installing"
        : manager.isInstalled ? "settings.model.status.installed" : "settings.model.status.not_installed"),
      isActive: manager.isInstalled,
      activeLabel: label("settings.model.in_use")
    ) {
      if manager.isInstalling {
        EchoButton(label("settings.model.downloading_button"), size: .regular) {}.disabled(true)
      } else if !manager.isInstalled {
        EchoButton(label(manager.failure == nil ? "settings.model.download" : "settings.model.retry"),
          symbol: "arrow.down.circle", size: .regular) {
            Task { await manager.install() }
          }
      }
    } footer: {
      EchoLocalizedText("transcription.alignment.details")
        .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task { await manager.refresh() }
  }

  private func label(_ key: String) -> String {
    EchoLocalization.string(key, locale: locale)
  }
}
