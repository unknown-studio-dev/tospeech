import SwiftUI
@preconcurrency import Translation

struct OnboardingView: View {
  @Environment(EchoStore.self) private var store
  @State private var step: Int
  @State private var level = ""
  @State private var offeredLanguages: [TranslationLanguage] = []
  @State private var packInstalled: Bool?
  @State private var setup: OnboardingSetupModel
  @State private var translationConfiguration: TranslationSession.Configuration?
  private let retryBootstrap: () -> Void

  init(
    parakeetModels: ParakeetModelManager?,
    pronunciationModels: PronunciationModelManager?,
    storageReady: Bool,
    retryBootstrap: @escaping () -> Void = {},
    initialStep: Int = 0
  ) {
    self.retryBootstrap = retryBootstrap
    _step = State(initialValue: initialStep)
    _setup = State(initialValue: OnboardingSetupModel(
      parakeetModels: parakeetModels,
      pronunciationModels: pronunciationModels,
      storageReady: storageReady))
  }

  var body: some View {
    HStack(spacing: 0) {
      stepRail
      VStack(spacing: 0) {
        ScrollView {
          Group {
            switch step {
            case 0: languageStep
            case 1: practiceStep
            default: setupStep
            }
          }
          .frame(maxWidth: 720, alignment: .leading)
          .padding(.horizontal, 56).padding(.vertical, 42)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        footer
      }
    }
    .foregroundStyle(EchoTheme.text).background(EchoTheme.canvas)
    .translationTask(translationConfiguration) { session in
      guard step == 2 else { return }
      await setup.run(using: session, store: store)
    }
    .task {
      let offered = await TranslationLanguageCatalog.supported()
      offeredLanguages = TranslationLanguage.sorted(offered, locale: store.preferences.language.locale)
      if !store.preferences.hasChosenTranslationLanguage,
        let match = TranslationLanguage.deviceDefault(among: offered)
      {
        store.preferences.translationLanguage = match.id
      }
    }
    .task(id: store.preferences.hasChosenTranslationLanguage ? store.preferences.translationLanguage : "") {
      packInstalled = nil
      guard store.preferences.hasChosenTranslationLanguage, !nativeLanguage.isNone else { return }
      packInstalled = await TranslationLanguageCatalog.isInstalled(nativeLanguage)
    }
    .onChange(of: level) { _, value in
      LearnerLevel(rawValue: value)?.apply(to: &store.preferences)
    }
    .onChange(of: step, initial: true) { _, value in
      if value == 1, level.isEmpty { level = LearnerLevel.matching(store.preferences)?.rawValue ?? "" }
    }
    .accessibilityIdentifier("onboarding-root")
  }

  private var nativeLanguage: TranslationLanguage {
    TranslationLanguage(identifier: store.preferences.translationLanguage)
  }

  private var stepRail: some View {
    VStack(alignment: .leading, spacing: 28) {
      EchoBrandLabel(size: 44, fontSize: 18)
      VStack(alignment: .leading, spacing: 18) {
        stepLabel(0, title: "Ngôn ngữ", symbol: "globe")
        stepLabel(1, title: "Cách bạn luyện", symbol: "person.crop.circle")
        stepLabel(2, title: "Thiết lập trên máy", symbol: "arrow.down.circle")
      }
      Spacer()
      Label("Xử lý cục bộ · dữ liệu ở trên Mac", systemImage: "lock.shield")
        .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 22)
    .frame(width: 260).frame(maxHeight: .infinity, alignment: .leading)
    .background(EchoTheme.surface)
  }

  private func stepLabel(_ index: Int, title: String, symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: step > index ? "checkmark.circle.fill" : symbol)
        .font(.system(size: 16, weight: .medium)).frame(width: 22)
        .foregroundStyle(step >= index ? EchoTheme.accent : EchoTheme.secondaryText)
      VStack(alignment: .leading, spacing: 2) {
        EchoLocalizedText(EchoCopy("onboarding.step", arguments: [.raw("\(index + 1)")]))
          .font(EchoFont.body(size: 10, weight: .medium))
          .foregroundStyle(EchoTheme.secondaryText)
        EchoLocalizedText(title).font(EchoFont.body(size: 13, weight: step == index ? .semibold : .regular))
      }
    }.opacity(step < index ? 0.68 : 1)
  }

  // MARK: Step 1 · languages

  private var languageStep: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 28) {
      heading("Chọn ngôn ngữ", "Ngôn ngữ hiển thị của ToSpeech và ngôn ngữ mẹ đẻ dùng để dịch từng câu.")
      EchoPanel {
        VStack(alignment: .leading, spacing: 20) {
          sectionTitle("Ngôn ngữ giao diện")
          EchoSegmented(selection: $store.preferences.language,
            options: AppLanguage.allCases.map { ($0, $0.titleKey) }, labelSize: 14)
            .frame(maxWidth: 360).accessibilityLabel("Ngôn ngữ giao diện")
          Divider().overlay(EchoTheme.separator)
          sectionTitle("Ngôn ngữ mẹ đẻ")
          EchoSelect(label: "Ngôn ngữ mẹ đẻ", selection: nativeLanguageSelection,
            options: nativeLanguageOptions, size: .regular)
            .frame(maxWidth: 360)
          if store.preferences.hasChosenTranslationLanguage, !nativeLanguage.isNone {
            EchoLocalizedText(packNote).font(EchoFont.body(size: 12))
              .foregroundStyle(EchoTheme.secondaryText)
          }
        }
      }
      EchoNotice(text: nativeLanguage.isNone && store.preferences.hasChosenTranslationLanguage
        ? "Bạn sẽ chỉ thấy câu tiếng Anh. Có thể chọn lại ngôn ngữ mẹ đẻ trong Cài đặt."
        : "Bản dịch của mỗi câu sẽ hiển thị bằng ngôn ngữ mẹ đẻ. Gói dịch offline được tải ở bước thiết lập.")
    }
  }

  private var nativeLanguageSelection: Binding<String> {
    Binding(
      get: { store.preferences.hasChosenTranslationLanguage ? store.preferences.translationLanguage : "" },
      set: { if !$0.isEmpty { store.preferences.selectTranslationLanguage($0) } })
  }

  /// The catalog answers asynchronously; until then the current choice stays
  /// selectable. "No translation" is always the last entry.
  private var nativeLanguageOptions: [(id: String, title: String)] {
    let locale = store.preferences.language.locale
    var offered = offeredLanguages
    if offered.isEmpty, store.preferences.hasChosenTranslationLanguage, !nativeLanguage.isNone {
      offered = [nativeLanguage]
    }
    return offered.map { ($0.id, $0.title(in: locale, among: offered)) }
      + [(TranslationLanguage.none.id, "Không dùng bản dịch")]
  }

  private var packNote: String {
    switch packInstalled {
    case nil: "Đang kiểm tra gói dịch…"
    case true?: "Gói dịch đã có trên máy."
    case false?: "Gói dịch offline sẽ được tải ở bước thiết lập."
    }
  }

  // MARK: Step 2 · level preset and starting preferences

  private var practiceStep: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 28) {
      heading("Chọn mức hiện tại của bạn",
        "ToSpeech điền sẵn tùy chọn luyện theo mức này. Bạn chỉnh ngay bên dưới hoặc trong Cài đặt sau.")
      EchoChoiceGroup(label: "Mức hiện tại", selection: $level, options: LearnerLevel.allCases.map {
        .init(id: $0.rawValue, title: $0.title, detail: $0.detail)
      })
      VStack(alignment: .leading, spacing: 12) {
        sectionTitle("Tùy chọn luyện ban đầu")
        EchoPanel {
          VStack(alignment: .leading, spacing: 18) {
            optionRow("Giọng tham khảo") {
              EchoSegmented(selection: $store.preferences.accent,
                options: [(ReferenceAccent.uk, "English · UK"), (.us, "English · US")], labelSize: 14)
                .accessibilityLabel("Giọng tham khảo")
            }
            optionRow("Tốc độ nghe") {
              EchoSelect(label: "Tốc độ nghe", selection: Binding(
                get: { String(store.preferences.speed) },
                set: { if let speed = Double($0) { store.preferences.speed = speed } }),
                options: PracticeOptions.speeds.map { (String($0), "\(EchoFormat.decimal($0))×") }, size: .regular)
            }
            optionRow("Số lần lặp") {
              EchoSelect(label: "Số lần lặp", selection: Binding(
                get: { String(store.preferences.repeats) },
                set: { if let repeats = Int($0) { store.preferences.repeats = repeats } }),
                options: PracticeOptions.repeatCounts.map { (String($0), "\($0)×") }, size: .regular)
            }
            optionRow("Đếm ngược") {
              EchoSelect(label: "Đếm ngược", selection: Binding(
                get: { String(store.preferences.countdown) },
                set: { if let countdown = Double($0) { store.preferences.countdown = countdown } }),
                options: PracticeOptions.countdowns.map { (String($0), "\(EchoFormat.decimal($0)) s") }, size: .regular)
            }
            optionRow("Giới hạn giờ chép chính tả") {
              DictationLimitSelect(limit: $store.preferences.dictationTimeLimit)
            }
            Divider().overlay(EchoTheme.separator)
            onboardingToggle("Hiện IPA theo từng từ", value: $store.preferences.showIPA)
            onboardingToggle("Hiện bản dịch", value: $store.preferences.showTranslation)
              .disabled(!store.preferences.usesTranslation)
            onboardingToggle("Hiện video khi mở bài", value: $store.preferences.video)
            onboardingToggle("Tự ghi âm sau khi nghe", value: $store.preferences.autoRecord)
          }
        }
      }
      EchoNotice(text: "ToSpeech chỉ tải audio của bài học. Video YouTube không được lưu về máy.")
    }
  }

  private func optionRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
    HStack(spacing: 20) {
      EchoLocalizedText(title).font(EchoFont.body(size: 14))
      Spacer(minLength: 12)
      control().frame(width: 220)
    }
  }

  // MARK: Step 3 · on-device setup

  private var setupStep: some View {
    VStack(alignment: .leading, spacing: 28) {
      heading("Chuẩn bị ToSpeech trên Mac này", "Các gói bắt buộc được tải và xác minh trước khi bạn có thể vào ứng dụng.")
      EchoPanel {
        VStack(spacing: 0) {
          ForEach(Array(setup.items.enumerated()), id: \.element.id) { index, item in
            setupRow(item)
            if index < setup.items.count - 1 { Divider().overlay(EchoTheme.separator) }
          }
        }
      }
      if let failure = setup.failure {
        EchoNotice(copy: failure, error: true)
      } else if setup.isComplete {
        EchoNotice(text: "Mọi thành phần bắt buộc đã sẵn sàng. Bạn có thể bắt đầu dùng ToSpeech.")
      } else {
        EchoNotice(text: "Giữ ToSpeech mở và duy trì kết nối mạng cho đến khi hoàn tất. macOS có thể yêu cầu xác nhận tải gói ngôn ngữ.")
      }
    }
  }

  private func setupRow(_ item: OnboardingSetupItem) -> some View {
    HStack(spacing: 14) {
      Group {
        switch item.state {
        case .waiting:
          Image(systemName: "circle").foregroundStyle(EchoTheme.secondaryText)
        case .running:
          EchoActivityIndicator()
        case .ready:
          Image(systemName: "checkmark.circle.fill").foregroundStyle(EchoTheme.success)
        case .failed:
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(EchoTheme.danger)
        }
      }.frame(width: 22, height: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        EchoLocalizedText(item.title).font(EchoFont.body(size: 14, weight: .semibold))
        EchoLocalizedText(item.detail).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }.padding(.vertical, 14)
  }

  private var footer: some View {
    HStack {
      if step > 0 && !setup.isRunning && !setup.isComplete {
        EchoButton("Quay lại", symbol: "arrow.left", size: .regular) {
          translationConfiguration = nil
          step -= 1
        }
      }
      Spacer()
      Text("\(step + 1) / 3").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
      Spacer()
      switch step {
      case 0:
        EchoButton("Tiếp tục", symbol: "arrow.right", kind: .primary, size: .regular) {
          step = 1
        }.disabled(!store.preferences.hasChosenTranslationLanguage)
      case 1:
        EchoButton("Tải và thiết lập", symbol: "arrow.down.circle", kind: .primary, size: .regular) {
          step = 2
          setup.includesTranslation = !nativeLanguage.isNone
          if nativeLanguage.isNone {
            // No package to download, so nothing drives a translationTask; start directly.
            Task { await setup.run(using: nil, store: store) }
          } else {
            translationConfiguration = AppleTranslationPreparer.configuration(for: nativeLanguage)
          }
        }.disabled(level.isEmpty)
      default:
        if setup.isComplete {
          EchoButton("Vào ToSpeech", symbol: "checkmark", kind: .primary, size: .regular) {
            store.preferences.hasCompletedOnboarding = true
            store.navigate(.library)
          }
        } else if setup.failure != nil {
          EchoButton("Thử lại", symbol: "arrow.clockwise", kind: .primary, size: .regular) {
            retryBootstrap()
            if nativeLanguage.isNone {
              Task { await setup.run(using: nil, store: store) }
            } else {
              translationConfiguration?.invalidate()
            }
          }
        } else {
          EchoButton("Đang thiết lập…", kind: .primary, size: .regular,
            state: .loading("Đang thiết lập…")) {}
        }
      }
    }
    .padding(.horizontal, 32).frame(height: 76)
    .background(EchoTheme.surface)
  }

  private func heading(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      EchoLocalizedText(title).font(EchoFont.heading(size: 28, weight: .semibold))
      EchoLocalizedText(subtitle).font(EchoFont.body(size: 15)).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    EchoLocalizedText(title).font(EchoFont.body(size: 14, weight: .semibold))
  }

  private func onboardingToggle(_ title: String, value: Binding<Bool>) -> some View {
    Toggle(isOn: value) { EchoLocalizedText(title).font(EchoFont.body(size: 14)) }
      .toggleStyle(EchoToggleStyle(minimumHeight: 40, fillsWidth: true, labelFirst: true))
  }
}

/// Picks the dictation writing time; "no limit" is stored as nil.
struct DictationLimitSelect: View {
  @Binding var limit: Int?

  var body: some View {
    EchoSelect(label: "Giới hạn giờ chép chính tả", selection: Binding(
      get: { String(limit ?? 0) },
      set: { limit = Int($0).flatMap { $0 == 0 ? nil : $0 } }),
      options: [("0", "Không giới hạn")] + DictationProgress.timeLimits.map { (String($0), "\($0) s") },
      size: .regular)
  }
}
