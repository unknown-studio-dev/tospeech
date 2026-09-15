import AppKit
import SwiftUI

struct EchoModalSizing {
  let height: CGFloat
  let bodyHeight: CGFloat
  let scrolls: Bool

  init(referenceHeight: CGFloat, availableHeight: CGFloat, header: CGFloat,
    content: CGFloat, footer: CGFloat) {
    height = min(max(referenceHeight, header + content + footer), availableHeight)
    bodyHeight = max(1, height - header - footer)
    scrolls = content > bodyHeight + 1
  }
}

/// Fits the body before resorting to scrolling; header and actions stay visible.
struct EchoModalLayout<Header: View, Content: View, Footer: View>: View {
  var width: CGFloat
  var referenceHeight: CGFloat
  @ViewBuilder var header: Header
  @ViewBuilder var content: Content
  @ViewBuilder var footer: Footer
  @State private var headerHeight: CGFloat = 0
  @State private var contentHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var availableHeight: CGFloat = .greatestFiniteMagnitude

  private var sizing: EchoModalSizing {
    EchoModalSizing(referenceHeight: referenceHeight, availableHeight: availableHeight,
      header: headerHeight, content: contentHeight, footer: footerHeight)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        header.fixedSize(horizontal: false, vertical: true)
          .frame(width: geometry.size.width)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
        ScrollView(.vertical) {
          content.frame(width: geometry.size.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        footer.fixedSize(horizontal: false, vertical: true)
          .frame(width: geometry.size.width)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
    }
    .frame(minWidth: 0, idealWidth: width, maxWidth: width,
      minHeight: 0, idealHeight: sizing.height, maxHeight: sizing.height)
    .background(EchoModalHeightReader(size: CGSize(width: width, height: sizing.height)) {
      availableHeight = $0
    })
    .presentationSizing(.fitted)
  }
}

/// Read the actual presenting window, rather than whichever window is currently key.
private struct EchoModalHeightReader: NSViewRepresentable {
  var size: CGSize
  var update: (CGFloat) -> Void
  func makeNSView(context: Context) -> Reader { Reader(size: size, update: update) }
  func updateNSView(_ view: Reader, context: Context) {
    view.size = size
    view.update = update
    view.refresh()
  }

  final class Reader: NSView {
    var size: CGSize
    var update: (CGFloat) -> Void
    private var refreshPending = false
    private var lastHeight: CGFloat?

    init(size: CGSize, update: @escaping (CGFloat) -> Void) {
      self.size = size
      self.update = update
      super.init(frame: .zero)
      for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
        NSWindow.willBeginSheetNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }

    @objc func refresh() {
      guard !refreshPending else { return }
      refreshPending = true
      // Defer until AppKit has attached the sheet and finished its current layout.
      Task { @MainActor [weak self] in
        guard let self else { return }
        refreshPending = false
        guard let window = self.window, let screen = window.screen else { return }
        let parent = window.sheetParent ?? window.parent
        let limit = min(screen.visibleFrame.height,
          parent?.contentLayoutRect.height ?? screen.visibleFrame.height)
        let height = max(240, limit - 48)
        if lastHeight != height {
          lastHeight = height
          update(height)
        }
        // SwiftUI can retain the first route's sheet size when its content changes
        // (for example Word → Timing). Resize only this attached presentation;
        // never change a main window or an app-owned standalone render host.
        guard let parent = window.sheetParent else { return }
        let desired = CGSize(width: min(size.width, parent.contentLayoutRect.width - 48),
          height: min(size.height, height))
        let current = window.contentLayoutRect.size
        guard abs(current.width - desired.width) > 0.5 || abs(current.height - desired.height) > 0.5 else { return }
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: desired)).size
        let center = CGPoint(x: parent.frame.midX, y: parent.frame.midY)
        window.setFrame(NSRect(x: center.x - frameSize.width / 2,
          y: center.y - frameSize.height / 2, width: frameSize.width, height: frameSize.height), display: true)
      }
    }
  }
}
