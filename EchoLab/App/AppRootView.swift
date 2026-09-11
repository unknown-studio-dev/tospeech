import SwiftUI

struct AppRootView: View {
  var settingsStartOnRecording = false
  var productionLibrary: ProductionLibraryModel?
  var productionShadowing: ProductionShadowingModel?
  var usesPreviewLibrary = false
  var productionLibraryError: String?
  var retryProductionLibrary: () -> Void = {}
  @Environment(EchoStore.self) private var store
  var body: some View {
    @Bindable var store = store
    HStack(spacing: 0) {
      navigation
      VStack(spacing: 0) {
        Group {
          switch store.route {
          case .library:
            if let productionLibrary {
              ProductionLibraryView(model: productionLibrary) { lesson in
                productionShadowing?.open(lesson, preferences: store.preferences)
                store.navigate(.shadowing)
              }
            }
            else if usesPreviewLibrary { LibraryView() }
            else { ProductionLibraryUnavailableView(
              error: productionLibraryError ?? "The production Library could not be initialized.",
              retry: retryProductionLibrary) }
          case .shadowing:
            if usesPreviewLibrary { ShadowingView() }
            else if let productionShadowing { ProductionShadowingView(model: productionShadowing) }
            else { ProductionShadowingGate() }
          case .progress: ProgressView()
          case .settings: SettingsView(recordingTab: settingsStartOnRecording)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .frame(maxWidth: .infinity).padding(.horizontal, contentInset).padding(
            .top, contentInset
          )
          .padding(.bottom, contentInset)
      }.frame(maxWidth: .infinity).background(EchoTheme.canvas)
    }.foregroundStyle(EchoTheme.ink).font(EchoFont.body(size: 13))
      .toolbar {
        ToolbarItem(placement: .navigation) {
          HStack(spacing: 8) {
            EchoBrandLabel(size: 24, fontSize: 14).frame(width: 128, alignment: .leading)
            EchoLocalizedText(
              store.route == .shadowing
                ? (usesPreviewLibrary
                  ? (store.selectedLesson?.title ?? "Luyện shadowing")
                  : (productionShadowing?.lesson?.title ?? "Luyện shadowing"))
                : routeTitle
            ).font(EchoFont.body(size: 14, weight: .semibold)).lineLimit(1)
          }
        }.sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
      }
      .onAppear {
        store.productionNavigationGuard = { [weak store, weak productionShadowing] destination in
          guard let store, store.route == .shadowing, destination != .shadowing,
            let productionShadowing
          else { return true }
          return productionShadowing.prepareForNavigation()
        }
      }
      .toolbarBackground(EchoTheme.surface, for: .windowToolbar)
      .overlay(alignment: .bottom) {
        if let error = store.storageError {
          EchoNotice(copy: error, error: true).padding(30)
        } else if let message = store.message {
          HStack {
            EchoLocalizedText(message).font(EchoFont.body(size: 12))
            EchoIconButton(symbol: "xmark", label: "Dismiss message") {
              store.message = nil
            }
          }
          .padding(16).background(EchoTheme.dark, in: RoundedRectangle(cornerRadius: 12))
          .foregroundStyle(EchoTheme.text).padding(.bottom, 42).padding(.horizontal, 100)
        }
      }
  }
  private var routeTitle: String {
    switch store.route {
    case .library: "Thư viện"
    case .shadowing: "Luyện shadowing"
    case .progress: "Tiến bộ theo video"
    case .settings: "Cài đặt"
    }
  }
  private var contentInset: CGFloat {
    store.route == .settings ? SettingsLayoutMetrics.pageInset : EchoMetrics.contentPadding
  }
  private var navigation: some View {
    VStack(spacing: 8) {
      ForEach(AppRoute.allCases.filter { $0 != .settings }) { route in
        EchoRowButton(selected: store.route == route, navigation: true) {
          store.navigate(route)
        } content: {
          Label {
            EchoLocalizedText(route.title)
          } icon: {
            Image(systemName: route == .library
              ? "rectangle.stack" : route == .shadowing ? "headphones" : "chart.bar")
          }
        }.echoHelp(route.title).echoAccessibilityLabel(route.title)
          .accessibilityIdentifier("nav-\(route.rawValue)")
      }
      Spacer()
      Divider().overlay(EchoTheme.separator)
      EchoRowButton(selected: store.route == .settings, navigation: true) {
        store.navigate(.settings)
      } content: {
        Label {
          EchoLocalizedText("Settings")
        } icon: {
          Image(systemName: "gearshape")
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.echoHelp("Settings")
        .echoAccessibilityLabel("Settings")
        .accessibilityIdentifier("nav-settings")
      Text(usesPreviewLibrary
        ? "UI preview · local sample data"
        : "Local processing · dữ liệu lưu trên máy")
        .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.secondaryText)
    }.padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 16)
      .frame(width: EchoMetrics.sidebarWidth).frame(maxHeight: .infinity)
      .background(EchoTheme.surface)
  }
}

private struct ProductionLibraryUnavailableView: View {
  let error: String
  let retry: () -> Void

  var body: some View {
    EchoPanel {
      VStack(spacing: 14) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.system(size: 28)).foregroundStyle(EchoTheme.danger)
        Text("Production Library unavailable")
          .font(EchoFont.heading(size: 20, weight: .medium))
        Text(error).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
          .multilineTextAlignment(.center).textSelection(.enabled)
        EchoButton("Retry", symbol: "arrow.clockwise", kind: .primary, action: retry)
      }.frame(maxWidth: 520).padding(28)
    }.frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ProductionShadowingGate: View {
  var body: some View {
    EchoPanel {
      EchoEmptyState(
        title: "Prepare a sentence before practicing",
        message: "Native source playback, microphone capture, and durable takes are ready. Transcript and sentence timing preparation is the next local processing step.",
        symbol: "waveform.badge.mic")
    }.frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
