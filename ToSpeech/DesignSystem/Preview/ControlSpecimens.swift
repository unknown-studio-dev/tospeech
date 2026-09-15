import SwiftUI

struct ControlSpecimens: View {
  @State private var query = ""
  @State private var invalidURL = "youtube"
  @State private var accent = "uk"
  @State private var enabled = true
  @State private var ipa = true
  @State private var speed = 0.75
  @State private var goal = "listen"
  @State private var taskState: EchoControlState = .idle

  var body: some View {
    SpecimenSection(title: "Button · tám trạng thái") {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 164))], alignment: .leading, spacing: 20) {
        ForEach(EchoInteractionPreview.allCases) { preview in
          VStack(alignment: .leading, spacing: 8) {
            EchoLocalizedText(preview.rawValue).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
            EchoButton("Lưu timing", kind: .primary, preview: preview, minimumWidth: 144) {}
          }
        }
        stateButton("Disabled", .disabled(DesignSystemFixtures.disabledReason))
        stateButton("Loading", .loading("Đang lưu…"))
        stateButton("Error", .error("Lưu chưa thành công. Thử lại."))
        stateButton("Success", .success("Đã lưu"))
      }
      EchoLocalizedText(DesignSystemFixtures.disabledReason).font(EchoFont.metadata).foregroundStyle(
        EchoTheme.secondaryText)
      HStack(spacing: 12) {
        EchoButton("Nghe nguồn", symbol: "play.fill", kind: .primary, size: .prominent) {}
        EchoButton("Thu âm", symbol: "mic", size: .prominent) {}
        EchoButton("Xóa bài", symbol: "trash", kind: .danger) {}
        EchoIconButton(symbol: "gearshape", label: "Chỉnh nội dung & timing") {}
        EchoIconButton(symbol: "gearshape", label: "Chưa có bài để chỉnh timing") {}.disabled(true)
      }
      HStack {
        EchoButton(
          "Lưu thử", symbol: "checkmark", kind: .primary, state: taskState,
          loadingTitle: "Đang lưu…"
        ) {
          taskState = .loading("Đang lưu…")
        }
        Text("Mẫu tương tác: không ghi dữ liệu bài học.").font(EchoFont.metadata).foregroundStyle(
          EchoTheme.secondaryText)
      }.task(id: taskState) {
        guard taskState.isLoading else { return }
        do {
          try await Task.sleep(for: .milliseconds(800))
          taskState = .success("Đã lưu")
        } catch { taskState = .idle }
      }
    }
    SpecimenSection(title: "Input · select · focus") {
      HStack(alignment: .top, spacing: 20) {
        EchoTextField(
          label: "Tên bài", text: $query, placeholder: "Tên hiển thị",
          helper: "Thông tin có thể chỉnh sau.")
        EchoTextField(
          label: "Link YouTube", text: $invalidURL, state: .error("Dán link video YouTube đầy đủ."))
      }
      EchoTextEditor(label: "dictation.prompt", text: $query, placeholder: "dictation.placeholder", editable: false)
      EchoSearchField(placeholder: "Tìm trong bài…", text: $query)
      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Giọng tham khảo").font(EchoFont.metadata)
          EchoSelect(
            label: "Giọng tham khảo", selection: $accent, options: DesignSystemFixtures.accents)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("Chưa thể đổi giọng").font(EchoFont.metadata)
          EchoSelect(
            label: "Giọng tham khảo", selection: $accent, options: DesignSystemFixtures.accents,
            state: .disabled("Kết thúc lượt thu trước khi đổi giọng."))
          Text("Kết thúc lượt thu trước khi đổi giọng.").font(EchoFont.metadata).foregroundStyle(
            EchoTheme.secondaryText)
        }
      }
      EchoTextField(
        label: "Chỉ đọc",
        text: .constant(EchoLocalization.string("Audio gốc · timeline không đổi", locale: locale)),
        readOnly: true)
    }
    SpecimenSection(title: "Lựa chọn & giá trị") {
      HStack(spacing: 24) {
        Toggle("Thu sau mỗi lượt nghe", isOn: $enabled).toggleStyle(EchoToggleStyle())
        EchoCheckbox(title: "Hiện IPA", isOn: $ipa)
      }
      EchoSegmented(selection: $accent, options: [("uk", "UK"), ("us", "US")]).frame(width: 240)
      EchoValueSlider(title: "Tốc độ nghe", value: $speed, range: 0.5...1.5)
      EchoChoiceGroup(
        label: "Mục tiêu luyện tập", selection: $goal, options: DesignSystemFixtures.choices)
    }
  }

  private func stateButton(_ label: String, _ state: EchoControlState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      EchoLocalizedText(label).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      EchoButton(
        label == "Error" ? "Thử lưu lại" : "Lưu timing", kind: .primary, state: state, loadingTitle: "Đang lưu…", minimumWidth: 144
      ) {}
    }
  }

  @Environment(\.locale) private var locale
}
