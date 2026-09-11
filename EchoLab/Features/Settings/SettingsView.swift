import SwiftUI

struct SettingsView: View {
  @Environment(EchoStore.self) private var store
  @State private var tab: SettingsTab

  init(recordingTab: Bool = false) {
    _tab = State(initialValue: recordingTab ? .recording : .general)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Cài đặt").font(EchoFont.heading(size: 28, weight: .semibold))
        Text("Điều chỉnh cách học, nghe và ghi âm của bạn.")
          .font(EchoFont.body(size: 16)).foregroundStyle(EchoTheme.secondaryText)
      }
      EchoSegmented(selection: $tab, options: SettingsTab.allCases.map { ($0, $0.title) },
        fillsWidth: false, labelSize: 14, horizontalPadding: 20)
        .fixedSize().accessibilityLabel("Nhóm cài đặt")
      ZStack(alignment: .topLeading) {
        tabContent(.general) { GeneralSettingsView() }
        tabContent(.recording) { RecordingModelsSettingsView() }
      }
      Group {
        if let error = store.storageError {
          EchoLocalizedText(error)
        } else {
          EchoLocalizedText("Tự động lưu trên máy · Không cần nhấn Lưu")
        }
      }
      .font(EchoFont.body(size: 14))
      .foregroundStyle(store.storageError == nil ? EchoTheme.secondaryText : EchoTheme.danger)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(EchoTheme.canvas).foregroundStyle(EchoTheme.text).preferredColorScheme(.dark)
  }

  // Keep both tabs mounted so scroll position, details and drafts survive switching.
  private func tabContent<Content: View>(_ value: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
    ScrollView {
      content().frame(maxWidth: .infinity, alignment: .leading)
    }.scrollIndicators(.visible)
      .opacity(tab == value ? 1 : 0)
      .allowsHitTesting(tab == value).disabled(tab != value).accessibilityHidden(tab != value)
  }
}

private enum SettingsTab: String, CaseIterable {
  case general, recording
  var title: String { self == .general ? "Chung" : "Ghi âm & models" }
}
