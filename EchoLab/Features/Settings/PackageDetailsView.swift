import SwiftUI

struct PackageDetailsView: View {
  @Environment(EchoStore.self) private var store
  var package: ModelPackage

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Divider()
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)],
        alignment: .leading, spacing: 16) {
        detail("Dung lượng tải / cài", package.footprint)
        detail("Giọng hỗ trợ", package.id == .phone ? "US English · dữ liệu mẫu" : "Chưa xác minh")
        detail("Tác vụ", package.subtitle)
        detail("RAM / độ trễ trên M1", "Chưa đo")
        detail("Giấy phép / runtime", package.details)
      }
      Text("Kích thước checkpoint không phải toàn bộ dung lượng app. Chưa xác minh hiệu năng, giấy phép hoặc khả năng tương thích.")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      if package.available && package.status == .notInstalled {
        EchoButton("Mô phỏng lỗi tải", kind: .danger, size: .regular) {
          store.downloadPackage(package.id, simulateFailure: true)
        }
      }
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText(label).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      EchoLocalizedText(value).font(EchoFont.body(size: 14, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
