import SwiftUI

struct MicrophoneRuntimeActions {
  var permissionDenied: Bool
  var permissionGranted: Bool
  var onListenOnly: () -> Void
  var onRetry: () -> Void
  var onOpenSettings: () -> Void
}

struct MicrophonePreviewSheet: View {
  @Environment(EchoStore.self) private var store
  var runtime: MicrophoneRuntimeActions? = nil
  var body: some View {
    EchoSheet(
      title: "Check microphone",
      subtitle: runtime == nil ? "Microphone permission · UI simulation" : "Microphone permission only",
      width: 560, close: close
    ) {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "mic.badge.plus").font(EchoFont.body(size: 36)).foregroundStyle(
          EchoTheme.muted)
        EchoLocalizedText(
          runtime == nil
            ? "The app can listen first or record directly after the countdown. This preview does not request or use your real microphone."
            : "Checking microphone access does not start a recording. Choose Record now when you are ready to capture a separate take."
        ).font(EchoFont.body(size: 14)).lineSpacing(5)
        if runtime?.permissionDenied ?? (store.practice.permission == "denied") {
          EchoNotice(
            text: runtime == nil
              ? "Access was denied in the preview. Retry access or continue listening."
              : "Microphone access is denied. Open System Settings, then retry, or continue listening.",
            error: true)
        } else if runtime?.permissionGranted == true {
          EchoNotice(text: "Microphone access is available. No recording has started.")
        }
        HStack {
          EchoButton(runtime == nil ? "Listen only" : "Close", action: close)
          if let runtime {
            EchoButton("Open System Settings", kind: .ghost, action: runtime.onOpenSettings)
            Spacer()
            EchoButton("Check again", symbol: "mic", kind: .primary, action: runtime.onRetry)
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
    .environment(\.locale, store.preferences.language.locale)
  }

  private func close() {
    if let runtime { runtime.onListenOnly() } else { store.practice.listenOnly() }
  }
}
