import SwiftUI

struct EchoUnsavedSheet: View {
  var onKeepEditing: () -> Void
  var onDiscard: () -> Void
  var onSave: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Giữ thay đổi timing?").font(EchoFont.heading(size: 22, weight: .semibold))
      Text("Bạn đã chỉnh mốc câu này. Lưu thay đổi, bỏ phần chỉnh sửa, hoặc tiếp tục biên tập.")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Spacer(minLength: 0)
        EchoButton(
          "Tiếp tục sửa", minimumWidth: 132, surface: EchoTheme.hover, action: onKeepEditing
        )
        .keyboardShortcut(.cancelAction)
        EchoButton("Bỏ thay đổi", minimumWidth: 132, surface: EchoTheme.hover, action: onDiscard)
        EchoButton("Lưu", kind: .primary, minimumWidth: 72, action: onSave)
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 620).frame(minHeight: 213)
      .background(EchoTheme.raised).foregroundStyle(EchoTheme.text).preferredColorScheme(.dark)
      .interactiveDismissDisabled().onExitCommand(perform: onKeepEditing)
  }
}
