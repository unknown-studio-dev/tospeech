import AppKit
import SwiftUI

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
  weak var store: EchoStore?
  weak var productionShadowing: ProductionShadowingModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--render-previews") {
        Task { @MainActor in
          do {
            try await PreviewRenderer.render()
            exit(0)
          } catch {
            print("Preview rendering failed: \(error)")
            exit(1)
          }
        }
      }
    #endif
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if store?.route == .shadowing, productionShadowing?.prepareForNavigation() == false {
      return .terminateCancel
    }
    return store?.practice.interrupt() == false ? .terminateCancel : .terminateNow
  }
}

struct WindowLifecycleGuard: NSViewRepresentable {
  var store: EchoStore
  var productionShadowing: ProductionShadowingModel?
  func makeNSView(context: Context) -> NSView {
    let view = WindowChromeProbe()
    view.configure = { [weak coordinator = context.coordinator] window in
      Self.applyMainWindowChrome(to: window, delegate: coordinator)
    }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    guard let view = view as? WindowChromeProbe else { return }
    context.coordinator.productionShadowing = productionShadowing
    view.configure = { [weak coordinator = context.coordinator] window in
      Self.applyMainWindowChrome(to: window, delegate: coordinator)
    }
    if let window = view.window {
      Self.applyMainWindowChrome(to: window, delegate: context.coordinator)
    }
  }
  func makeCoordinator() -> Coordinator {
    Coordinator(store: store, productionShadowing: productionShadowing)
  }
  static func applyMainWindowChrome(to window: NSWindow, delegate: NSWindowDelegate?) {
    window.delegate = delegate
    // Keep the title for Window menu, Mission Control and restoration metadata.
    // Only suppress its duplicate visual rendering beside the custom route toolbar item.
    window.titleVisibility = .hidden
  }
  @MainActor final class Coordinator: NSObject, NSWindowDelegate {
    let store: EchoStore
    weak var productionShadowing: ProductionShadowingModel?
    init(store: EchoStore, productionShadowing: ProductionShadowingModel?) {
      self.store = store
      self.productionShadowing = productionShadowing
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if store.route == .shadowing, productionShadowing?.prepareForNavigation() == false {
        return false
      }
      return store.practice.interrupt()
    }
  }
}

private final class WindowChromeProbe: NSView {
  var configure: ((NSWindow) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { configure?(window) }
  }
}
