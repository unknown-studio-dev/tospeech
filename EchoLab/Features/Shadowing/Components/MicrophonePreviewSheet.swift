import SwiftUI

struct MicrophoneRuntimeActions {
  var permissionDenied: Bool
  var onListenOnly: () -> Void
  var onRetry: () -> Void
  var onOpenSettings: () -> Void
}

struct MicrophonePreviewSheet: View {
  @Environment(EchoStore.self) private var store
  var runtime: MicrophoneRuntimeActions? = nil
  var body: some View {
    EchoSheet(
      title: "Your voice comes next",
      subtitle: runtime == nil ? "Microphone permission · UI simulation" : "Microphone permission",
      width: 560, close: close
    ) {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "mic.badge.plus").font(EchoFont.body(size: 36)).foregroundStyle(
          EchoTheme.muted)
        EchoLocalizedText(
          runtime == nil
            ? "The app listens to the source first, then records a separate take. This preview does not request or use your real microphone."
            : "The app listens to the complete source first, then records a separate take using the selected microphone."
        ).font(EchoFont.body(size: 14)).lineSpacing(5)
        if runtime?.permissionDenied ?? (store.practice.permission == "denied") {
          EchoNotice(
            text: runtime == nil
              ? "Access was denied in the preview. Retry access or continue listening."
              : "Microphone access is denied. Open System Settings, then retry, or continue listening.",
            error: true)
        }
        HStack {
          EchoButton("Listen only", action: close)
          if let runtime {
            EchoButton("Open System Settings", kind: .ghost, action: runtime.onOpenSettings)
            Spacer()
            EchoButton("Retry", symbol: "mic", kind: .primary, action: runtime.onRetry)
          } else {
            EchoButton("Simulate denial", kind: .ghost) { store.practice.denyPermission() }
            Spacer()
            EchoButton("Allow in preview", symbol: "mic", kind: .primary) {
              store.practice.allowPermission()
            }
          }
        }
      }
    }
  }

  private func close() {
    if let runtime { runtime.onListenOnly() } else { store.practice.listenOnly() }
  }
}
