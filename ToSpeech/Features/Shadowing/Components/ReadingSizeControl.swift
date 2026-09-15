import SwiftUI

struct ReadingSizeControl: View {
  @Environment(EchoStore.self) private var store
  @State private var showing = false
  @FocusState private var focused: Bool

  var body: some View {
    EchoButton("Cỡ chữ", symbol: "textformat.size") { showing.toggle() }
      .focused($focused)
      .accessibilityValue("\(store.preferences.readingPercent)%")
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        ReadingSizePopover(
          percent: Binding(
            get: { store.preferences.readingPercent },
            set: { store.preferences.readingPercent = $0 })
        )
        .onExitCommand { showing = false }
      }
      .onChange(of: showing) { _, open in if !open { focused = true } }
  }
}

struct ReadingSizePopover: View {
  @Binding var percent: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Cỡ chữ câu luyện").font(EchoFont.body(size: 15, weight: .semibold))
      HStack {
        Text("Độ phóng chữ").foregroundStyle(EchoTheme.secondaryText)
        Spacer()
        Text("\(percent)%").monospacedDigit().font(EchoFont.body(size: 15, weight: .semibold))
      }
      HStack(spacing: 12) {
        EchoIconButton(symbol: "minus", label: "Giảm cỡ chữ 10%", surface: EchoTheme.hover) {
          adjust(-ReadingSize.step)
        }
        .disabled(percent <= ReadingSize.range.lowerBound)
        EchoSlider(
          value: Binding(
            get: { Double(percent) }, set: { percent = ReadingSize.normalized(Int($0.rounded())) }),
          range: Double(ReadingSize.range.lowerBound)...Double(ReadingSize.range.upperBound),
          step: Double(ReadingSize.step), label: "Độ phóng chữ câu luyện", valueLabel: "\(percent)%"
        )
        EchoIconButton(symbol: "plus", label: "Tăng cỡ chữ 10%", surface: EchoTheme.hover) {
          adjust(ReadingSize.step)
        }
        .disabled(percent >= ReadingSize.range.upperBound)
      }
      Text("Tiếng Anh, IPA và bản dịch cùng thay đổi.\nKhông đổi kích thước phần còn lại của app.")
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      EchoButton("Mặc định", minimumWidth: 280, surface: EchoTheme.surface) {
        percent = ReadingSize.defaultPercent
      }
      .disabled(percent == ReadingSize.defaultPercent)
    }
    .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.text)
    .padding(20).frame(width: 320).background(EchoTheme.raised)
    .transaction { $0.animation = nil }
  }

  private func adjust(_ delta: Int) { percent = ReadingSize.normalized(percent + delta) }
}
