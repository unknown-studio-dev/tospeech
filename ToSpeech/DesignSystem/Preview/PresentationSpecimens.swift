import SwiftUI

struct PresentationSpecimens: View {
  @State private var dialog = false
  @State private var popover = false
  @State private var repeatCount = "5"
  @State private var autoRecord = false
  @State private var editedName = ""
  @State private var saved = false
  @State private var seededName = false
  @Environment(\.locale) private var locale
  var body: some View {
    SpecimenSection(title: "Sheet căn giữa · footer cố định") {
      Text("Sheet dùng cửa sổ native, cuộn phần nội dung và luôn giữ nút hành động ở đáy.")
        .foregroundStyle(EchoTheme.secondaryText)
      EchoButton("Mở sheet", symbol: "rectangle.on.rectangle", kind: .primary) { dialog = true }
        .sheet(isPresented: $dialog) {
          EchoDialog(
            title: "Chỉnh bài luyện", subtitle: "Mẫu component sheet trong app.", height: 430,
            close: { dialog = false }
          ) {
            EchoTextField(
              label: "Tên bài", text: $editedName, helper: "Thay đổi chỉ áp dụng cho ví dụ này.")
            EchoInlineFeedback(
              title: "Nội dung cuộn độc lập",
              message: "Các màn có draft sẽ tự quản lý xác nhận khi đóng.")
          } footer: {
            EchoButton("Hủy") { dialog = false }
            EchoButton("Lưu", symbol: "checkmark", kind: .primary) {
              saved = true
              dialog = false
            }
          }
        }
      if saved { EchoStatusBadge(title: "Đã lưu ví dụ", tone: .success) }
    }
    SpecimenSection(title: "Popover theo ngữ cảnh") {
      EchoButton("Tùy chọn lặp", symbol: "repeat") { popover = true }
        .popover(isPresented: $popover, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 16) {
            Text("Lặp một câu").font(EchoFont.heading(size: 18, weight: .semibold))
            EchoSelect(
              label: "Số vòng", selection: $repeatCount,
              options: [("3", "3 vòng"), ("5", "5 vòng"), ("10", "10 vòng")])
            Toggle("Thu sau mỗi lượt nghe", isOn: $autoRecord).toggleStyle(EchoToggleStyle())
            Text("Micro chỉ mở khi đến lượt nói.").font(EchoFont.metadata).foregroundStyle(
              EchoTheme.secondaryText)
          }.padding(20).frame(width: 320).background(EchoTheme.surface)
            .foregroundStyle(EchoTheme.text).preferredColorScheme(.dark)
        }
      Text("Đóng bằng Escape hoặc bấm bên ngoài. Menu select không bị cắt bởi vùng cuộn.")
        .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
    }.onAppear {
      guard !seededName else { return }
      editedName = EchoLocalization.string("Bài luyện mẫu", locale: locale)
      seededName = true
    }
  }
}
