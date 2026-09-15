import SwiftUI

struct GeneralSettingsView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.appUpdateChecker) private var updateChecker
  @Environment(\.openURL) private var openURL
  @State private var confirmsReset = false
  @State private var offeredLanguages: [TranslationLanguage] = []

  var body: some View {
    SettingsColumns(composition: .general) {
      VStack(alignment: .leading, spacing: 24) { languages; levelPreset; reading }
      VStack(alignment: .leading, spacing: 24) { video; localData; about }
    }
    .confirmationDialog("Khôi phục dữ liệu mẫu?", isPresented: $confirmsReset) {
      Button("Khôi phục", role: .destructive) { store.restoreDemo() } // native-control: confirmation
      Button("Hủy", role: .cancel) {} // native-control: confirmation
    } message: {
      Text("Bài luyện, bản thu, kết quả, gói model và cài đặt sẽ trở về dữ liệu mẫu ban đầu.")
    }
  }

  private var languages: some View {
    SettingsSection(title: "Ngôn ngữ", subtitle: "Giao diện và ngôn ngữ mẹ đẻ dùng cho bản dịch.", spacing: 12) {
      SettingsPreferenceRow(title: "Ngôn ngữ giao diện") {
        EchoSelect(label: "Ngôn ngữ giao diện", selection: Binding(
          get: { store.preferences.language.rawValue },
          set: { if let language = AppLanguage(rawValue: $0) { store.preferences.language = language } }),
          options: AppLanguage.allCases.map { ($0.rawValue, $0.titleKey) }, size: .regular)
          .frame(width: 250)
      }
      Divider().overlay(EchoTheme.raised)
      SettingsPreferenceRow(title: "Ngôn ngữ mẹ đẻ") {
        EchoSelect(label: "Ngôn ngữ mẹ đẻ", selection: Binding(
          get: { store.preferences.translationLanguage },
          set: { if !$0.isEmpty { store.preferences.selectTranslationLanguage($0) } }),
          options: nativeLanguageOptions, size: .regular)
          .frame(width: 250)
      }
      help("Bản dịch theo ngôn ngữ mới được chuẩn bị khi bạn mở lại bài học. macOS có thể hỏi tải gói dịch.")
    }
    .task {
      let offered = await TranslationLanguageCatalog.supported()
      offeredLanguages = TranslationLanguage.sorted(offered, locale: store.preferences.language.locale)
    }
  }

  /// The catalog answers asynchronously; until then the current choice stays selectable.
  private var nativeLanguageOptions: [(id: String, title: String)] {
    let current = TranslationLanguage(identifier: store.preferences.translationLanguage)
    let offered = offeredLanguages.isEmpty ? (current.isNone ? [] : [current]) : offeredLanguages
    let locale = store.preferences.language.locale
    return offered.map { ($0.id, $0.title(in: locale, among: offered)) }
      + [(TranslationLanguage.none.id, "Không dùng bản dịch")]
  }

  private var levelPreset: some View {
    let matching = LearnerLevel.matching(store.preferences)
    return SettingsSection(title: "Cách bạn luyện", subtitle: "Điền lại tùy chọn luyện theo mức của bạn.", spacing: 12) {
      HStack(spacing: 10) {
        ForEach(LearnerLevel.allCases) { level in
          EchoButton(level.title, kind: matching == level ? .primary : .secondary, size: .regular) {
            level.apply(to: &store.preferences)
          }
        }
      }
      help("Đặt lại tốc độ, số lần lặp, đếm ngược, bản dịch, tự ghi âm và giới hạn giờ chép chính tả.")
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
      SettingsPreferenceRow(title: "Giới hạn giờ chép chính tả") {
        DictationLimitSelect(limit: $store.preferences.dictationTimeLimit).frame(width: 150)
      }
      Divider().overlay(EchoTheme.raised)
      toggle("Hiện IPA", value: $store.preferences.showIPA)
      toggle("Hiện bản dịch", value: $store.preferences.showTranslation)
        .disabled(!store.preferences.usesTranslation)
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

  private var about: some View {
    SettingsSection(title: "Giới thiệu", subtitle: "Phiên bản, tác giả và cập nhật.", spacing: 12) {
      SettingsPreferenceRow(title: "Phiên bản") {
        Text(verbatim: "\(AppInfo.version) (\(AppInfo.build))")
          .font(EchoFont.body(size: 16)).foregroundStyle(EchoTheme.secondaryText)
          .accessibilityLabel(Text(verbatim: "\(AppInfo.displayName) \(AppInfo.version)"))
      }
      SettingsPreferenceRow(title: "Tác giả") {
        Text(verbatim: AppInfo.author)
          .font(EchoFont.body(size: 16)).foregroundStyle(EchoTheme.secondaryText)
      }
      help(AppInfo.copyright)
      EchoButton("Ghé UnknownStudio", symbol: "arrow.up.right", kind: .secondary, size: .regular) {
        openURL(AppInfo.studioURL)
      }
      if let updateChecker {
        Divider().overlay(EchoTheme.raised)
        updateStatus(updateChecker)
      }
    }
  }

  @ViewBuilder private func updateStatus(_ checker: AppUpdateChecker) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      switch checker.state {
      case .idle, .checking:
        EmptyView()
      case .upToDate:
        help("Bạn đang dùng bản mới nhất.")
      case .available(let info):
        EchoLocalizedText(EchoCopy("Đã có bản %@.", arguments: [.raw(info.version)]))
          .font(EchoFont.body(size: 16))
        EchoButton("Tải bản mới", symbol: "arrow.down.circle", kind: .primary, size: .regular) {
          openURL(URL(string: info.downloadURL) ?? AppInfo.releasesURL)
        }
      case .failed:
        EchoLocalizedText("Không kiểm tra được bản mới.")
          .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.danger)
      }
      EchoButton(
        "Kiểm tra bản mới", symbol: "arrow.clockwise", kind: .secondary, size: .regular,
        state: checker.state == .checking ? .loading("Đang kiểm tra bản mới…") : .idle
      ) {
        Task { await checker.check() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task { await checker.checkOnAppear() }
  }

  private func help(_ text: String) -> some View {
    EchoLocalizedText(text).font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func toggle(_ title: String, value: Binding<Bool>) -> some View {
    Toggle(isOn: value) {
      EchoLocalizedText(title).font(EchoFont.body(size: 16))
    }
    .toggleStyle(EchoToggleStyle(minimumHeight: 40, fillsWidth: true, labelFirst: true))
    .echoAccessibilityLabel(title)
  }
}
