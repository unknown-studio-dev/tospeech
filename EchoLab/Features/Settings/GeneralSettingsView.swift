import SwiftUI

struct GeneralSettingsView: View {
  @Environment(EchoStore.self) private var store
  @State private var confirmsReset = false

  var body: some View {
    SettingsColumns(composition: .general) {
      VStack(alignment: .leading, spacing: 24) { learning; reading }
      VStack(alignment: .leading, spacing: 24) { video; localData }
    }
    .confirmationDialog("Khôi phục dữ liệu mẫu?", isPresented: $confirmsReset) {
      Button("Khôi phục", role: .destructive) { store.restoreDemo() } // native-control: confirmation
      Button("Hủy", role: .cancel) {} // native-control: confirmation
    } message: {
      Text("Bài luyện, bản thu, kết quả, gói model và cài đặt sẽ trở về dữ liệu mẫu ban đầu.")
    }
  }

  private var learning: some View {
    SettingsSection(title: "Cách bạn học", subtitle: "Mục tiêu và mức tự đánh giá của bạn.", spacing: 12) {
      SettingsPreferenceRow(title: "Ngôn ngữ") {
        EchoSelect(label: "Ngôn ngữ", selection: Binding(
          get: { store.preferences.language.rawValue },
          set: { if let language = AppLanguage(rawValue: $0) { store.preferences.language = language } }),
          options: AppLanguage.allCases.map { ($0.rawValue, $0.titleKey) }, size: .regular)
          .frame(width: 250)
      }
      Divider().overlay(EchoTheme.raised)
      SettingsPreferenceRow(title: "Mục tiêu luyện") {
        EchoSelect(label: "Mục tiêu luyện", selection: Binding(
          get: { store.preferences.learningGoal?.rawValue ?? "" },
          set: { store.preferences.learningGoal = LearningGoal(rawValue: $0) }),
          options: [("", "Chưa chọn")] + LearningGoal.allCases.map { ($0.rawValue, $0.title) }, size: .regular)
          .frame(width: 250)
      }
      Divider().overlay(EchoTheme.raised)
      SettingsPreferenceRow(title: "Mức tự đánh giá") {
        EchoSelect(label: "Mức tự đánh giá", selection: Binding(
          get: { store.preferences.selfAssessedLevel?.rawValue ?? "" },
          set: { store.preferences.selfAssessedLevel = SelfAssessedLevel(rawValue: $0) }),
          options: [("", "Chưa chọn")] + SelfAssessedLevel.allCases.map { ($0.rawValue, $0.title) }, size: .regular)
          .frame(width: 250)
      }
    }
  }

  private var reading: some View {
    @Bindable var store = store
    return SettingsSection(title: "Nghe & đọc theo", subtitle: "Áp dụng mặc định khi bạn mở một bài luyện.", spacing: 12) {
      SettingsPreferenceRow(title: "Giọng tham khảo") {
        EchoSegmented(selection: $store.preferences.accent,
          options: [(ReferenceAccent.uk, "English · UK"), (.us, "English · US")], labelSize: 14)
          .frame(width: 250).accessibilityLabel("Giọng tham khảo")
      }
      SettingsPreferenceRow(title: "Tốc độ nghe") {
        EchoSelect(label: "Tốc độ nghe", selection: Binding(
          get: { String(store.preferences.speed) },
          set: { if let speed = Double($0) { store.preferences.speed = speed } }),
          options: PracticeOptions.speeds.map { (String($0), "\(EchoFormat.decimal($0))×") }, size: .regular)
          .frame(width: 150)
      }
      Divider().overlay(EchoTheme.raised)
      toggle("Hiện IPA", value: $store.preferences.showIPA)
      toggle("Hiện bản dịch tiếng Việt", value: $store.preferences.showTranslation)
      help("UK/US chỉ đổi giọng tham khảo, không đổi audio gốc.")
    }
  }

  private var video: some View {
    @Bindable var store = store
    return SettingsSection(title: "Video", subtitle: "Xem khẩu hình khi cần, vẫn ưu tiên nghe.") {
      toggle("Hiện video khi mở bài", value: $store.preferences.video)
      Divider().overlay(EchoTheme.raised)
      help("Khi tắt, giữ ảnh thumbnail ở khung 16:9. Audio gốc vẫn phát bình thường.")
      help("Video YouTube luôn tắt âm và đi theo audio. Không tải video về máy.")
    }
  }

  private var localData: some View {
    SettingsSection(title: "Dữ liệu trên máy", subtitle: "Bài luyện, bản thu và cài đặt được lưu cục bộ.") {
      help("Hiện đang dùng dữ liệu preview.")
      Divider().overlay(EchoTheme.raised)
      help("Khôi phục sẽ thay bài luyện, bản thu và kết quả mẫu hiện tại.")
      EchoButton("Khôi phục dữ liệu mẫu", symbol: "arrow.counterclockwise", kind: .danger, size: .regular) {
        confirmsReset = true
      }
    }
  }

  private func help(_ text: String) -> some View {
    EchoLocalizedText(text).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func toggle(_ title: String, value: Binding<Bool>) -> some View {
    SettingsPreferenceRow(title: title) {
      Toggle(isOn: value) { EchoLocalizedText(title) }
        .toggleStyle(EchoToggleStyle(showsLabel: false, minimumHeight: 24))
        .echoAccessibilityLabel(title)
    }
  }
}
