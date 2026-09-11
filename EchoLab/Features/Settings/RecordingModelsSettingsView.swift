import SwiftUI

struct RecordingModelsSettingsView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  @State private var details: EngineID?
  @State private var removeCandidate: EngineID?

  var body: some View {
    SettingsColumns(composition: .recording) {
      VStack(alignment: .leading, spacing: 24) {
        recording
        SettingsSection(title: "Mỗi lượt, một bản thu",
          subtitle: "Không phát audio nguồn cùng lúc với mic. Chuyển model không làm mất bản thu hay kết quả cũ.", titleSize: 16) {}
      }
      models
    }
    .confirmationDialog("Xóa gói model?", isPresented: Binding(
      get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } })
    ) {
      if let id = removeCandidate {
        Button(role: .destructive) { // native-control: confirmation
          store.removePackage(id)
          removeCandidate = nil
        } label: {
          Text(verbatim: EchoLocalization.format(
            "model.action.delete", locale: locale, arguments: [id.title]))
        }
      }
      Button("Giữ lại", role: .cancel) {} // native-control: confirmation
    } message: {
      Text("Bản thu và các kết quả đánh giá trước đây vẫn được giữ lại.")
    }
  }

  private var recording: some View {
    @Bindable var store = store
    return SettingsSection(title: "Ghi âm", subtitle: "Nghe xong → đếm ngược → ghi âm.", spacing: 20) {
      RecordingPreferenceField(label: "Đếm ngược",
        help: "Thời gian chuẩn bị trước khi bắt đầu thu.",
        value: $store.preferences.countdown, choices: PracticeOptions.countdowns)
      RecordingPreferenceField(label: "Dừng sau im lặng",
        help: "Chỉ tính sau khi bạn đã bắt đầu nói.",
        value: $store.preferences.silence, choices: [1, 1.2, 2, 3, 5])
      RecordingPreferenceField(label: "Độ dài bản thu tối đa",
        help: "Bạn vẫn có thể chủ động dừng sớm.",
        value: $store.preferences.maxDuration, choices: [15, 30, 60, 120])
    }
  }

  private var models: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        Text("Model đánh giá").font(EchoFont.heading(size: 20, weight: .semibold))
        Spacer()
        EchoButton(store.preferences.activeEngine == nil ? "Đánh giá đang tắt" : "Tắt đánh giá", size: .regular) {
          store.activateEngine(nil)
        }.disabled(store.preferences.activeEngine == nil)
      }
      Text("Chỉ một model hoạt động. Trạng thái dưới đây là dữ liệu mẫu, không phải gói đã kiểm chứng.")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      ForEach(store.packages) { package in
        ModelPackageCard(package: package, expanded: details == package.id,
          toggleDetails: { details = details == package.id ? nil : package.id },
          requestRemove: { removeCandidate = package.id })
      }
      Text("Dung lượng tải, dung lượng cài và RAM được ghi riêng trong Chi tiết. Chưa có số đo thì không ước đoán.")
        .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
    }
  }
}

private struct RecordingPreferenceField: View {
  @Environment(\.locale) private var locale
  let label: String
  let help: String
  @Binding var value: Double
  let choices: [Double]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EchoLocalizedText(label).font(EchoFont.body(size: 16))
      EchoSelect(label: label, selection: Binding(
        get: { String(value) },
        set: { if let parsed = Double($0), parsed.isFinite, parsed > 0 { value = parsed } }),
        options: Array(Set(choices + [value])).filter { $0.isFinite && $0 > 0 }.sorted().map {
          (String($0), EchoLocalization.format(
            "duration.seconds", locale: locale, arguments: [EchoFormat.decimal($0)]))
        }, size: .regular)
      EchoLocalizedText(help).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
