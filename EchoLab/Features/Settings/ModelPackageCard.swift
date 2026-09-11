import SwiftUI

struct ModelPackageCard: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var package: ModelPackage
  var expanded: Bool
  var toggleDetails: () -> Void
  var requestRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        EchoLocalizedText(package.id.title).font(EchoFont.body(size: 16, weight: .semibold))
        Spacer()
        if isActive {
          Label("Đang dùng", systemImage: "checkmark.circle")
            .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.success).fixedSize()
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          status
          Spacer(minLength: 0)
          controls
        }
        VStack(alignment: .leading, spacing: 12) {
          status
          HStack { Spacer(); controls }
        }
      }
      if package.status == .downloading {
        EchoLoading(title: "Tiến trình tải (mô phỏng)", fraction: package.progress)
      }
      if let error = package.error { EchoNotice(text: error, error: true) }
      if expanded { PackageDetailsView(package: package) }
    }
    .padding(.horizontal, 20).padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isActive ? EchoTheme.success : .clear))
  }

  private var status: some View {
    EchoLocalizedText(statusLine).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var controls: some View {
    HStack(spacing: 12) {
      EchoButton(expanded ? "Ẩn chi tiết" : "Chi tiết", kind: .ghost, size: .regular, action: toggleDetails)
      actions
    }.fixedSize()
  }

  @ViewBuilder private var actions: some View {
    switch package.status {
    case .notInstalled:
      EchoButton("Tải gói", symbol: "arrow.down.circle", size: .regular) { store.downloadPackage(package.id) }
    case .downloading:
      EchoButton("Hủy tải", size: .regular) { store.cancelPackageDownload(package.id) }
    case .verifying:
      EchoButton("Đang xác minh…", size: .regular) {}.disabled(true)
    case .failed:
      EchoButton("Thử lại", size: .regular) { store.downloadPackage(package.id) }
    case .installed:
      if !isActive {
        EchoButton("Kích hoạt", kind: .primary, size: .regular) { store.activateEngine(package.id) }
      }
      EchoIconButton(symbol: "trash", label: isActive
        ? "Tắt đánh giá hoặc chọn model khác trước khi xóa"
        : EchoLocalization.format(
          "model.action.delete", locale: locale, arguments: [package.id.title]),
        size: .regular, action: requestRemove)
        .disabled(isActive)
    case .unavailable:
      EchoButton("Chưa khả dụng", size: .regular) {}.disabled(true)
    }
  }

  private var isActive: Bool { store.preferences.activeEngine == package.id }
  private var statusLine: String {
    switch package.status {
    case .unavailable: package.details
    case .notInstalled:
      EchoLocalization.format(
        "model.status.not_installed", locale: locale,
        arguments: [EchoLocalization.string(package.subtitle, locale: locale)])
    case .downloading:
      EchoLocalization.format(
        "model.status.downloading", locale: locale, arguments: [Int(package.progress * 100)])
    case .verifying: "Đang xác minh toàn bộ gói (mô phỏng)…"
    case .installed: "Đã cài · dữ liệu mẫu"
    case .failed: "Tải thất bại · model đang dùng không đổi"
    }
  }
}
