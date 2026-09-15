import SwiftUI

enum D00CatalogGroup: String, CaseIterable, Identifiable {
  case buttons = "Button & icon"
  case fields = "Input & Select"
  case selections = "Switch, checkbox, slider"
  case words = "Word · IPA"
  case feedback = "Capture & recovery"
  case overlays = "Sheet & popover"
  case transport = "Transport & nhận xét"
  case compositions = "Row · thumbnail · số"
  var id: String { rawValue }
}

/// Uses shipping controls with an isolated in-memory store: gallery actions never edit user lessons.
struct D00CatalogView: View {
  @State var group: D00CatalogGroup = .buttons
  @State private var store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
  @State private var text = "thought"
  @State private var accent = "uk"
  @State private var on = false
  @State private var mixed = true
  @State private var speed = 0.75
  @State private var percent = 100
  @State private var choice = "listen"
  @State private var presentation: String?
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      EchoSelect(
        label: "Nhóm D00",
        selection: Binding(
          get: { group.rawValue },
          set: {
            if let next = D00CatalogGroup(rawValue: $0) { group = next }
          }), options: D00CatalogGroup.allCases.map { ($0.rawValue, $0.rawValue) }
      ).frame(width: 300)
      Text("Component thật · SF Pro / SF Symbols · dữ liệu minh họa, không phát audio hay mở mic.")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      specimens
    }.environment(store)
      .sheet(
        isPresented: Binding(get: { presentation != nil }, set: { if !$0 { presentation = nil } })
      ) {
        switch presentation {
        case "import": ImportSheet(store: store)
        case "delete":
          if let lesson = store.selectedLesson { DeleteLessonSheet(lesson: lesson, store: store) }
        case "unsaved": EchoUnsavedSheet(onKeepEditing: close, onDiscard: close, onSave: close)
        default: EmptyView()
        }
      }
  }

  @ViewBuilder private var specimens: some View {
    switch group {
    case .compositions:
      HStack(alignment: .top, spacing: 24) {
        VStack(spacing: 8) {
          EchoRowButton(navigation: true, action: {}) { Label("Library", systemImage: "rectangle.stack") }
          EchoRowButton(selected: true, navigation: true, action: {}) { Label("Shadowing", systemImage: "headphones") }
          EchoRowButton(action: {}) { Text("Disabled row") }.disabled(true)
          EchoNumberField(label: "Start", value: speed) { speed = $0 }
        }.frame(width: 280)
        if let lesson = store.selectedLesson {
          EchoMediaThumbnail(name: lesson.thumbnail, title: lesson.title,
            duration: EchoFormat.time(lesson.duration), onOpen: {}, onDelete: { presentation = "delete" })
            .frame(width: 320)
        }
      }
    case .buttons:
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 24) {
        ForEach(EchoInteractionPreview.allCases) { state in
          sample(state.rawValue) {
            EchoButton(
              "Lưu timing", symbol: "checkmark", kind: .primary, preview: state, minimumWidth: 144
            ) {}
          }
        }
        sample("Disabled") {
          EchoButton(
            "Lưu timing", symbol: "checkmark", kind: .primary,
            state: .disabled("Chọn một câu trước khi lưu."), minimumWidth: 144
          ) {}
        }
        sample("Loading") {
          EchoButton(
            "Lưu timing", symbol: "checkmark", kind: .primary, state: .loading("Đang lưu…"),
            loadingTitle: "Đang lưu…", minimumWidth: 144
          ) {}
        }
        sample("Error") {
          EchoButton(
            "Thử lưu lại", kind: .primary, state: .error("Giữ draft · thử lưu lại"),
            minimumWidth: 144
          ) {}
        }
        sample("Success") {
          EchoButton("Lưu timing", kind: .primary, state: .success("Đã lưu"), minimumWidth: 144) {}
        }
      }
      HStack(spacing: 24) {
        EchoButton("Nghe mẫu", symbol: "play", kind: .primary, size: .practice, minimumWidth: 160) {
        }
        EchoButton("Thu âm", symbol: "mic", size: .practice, minimumWidth: 160) {}
        EchoButton("Dừng & lưu", symbol: "stop", size: .practice, minimumWidth: 160) {}
      }
      HStack(spacing: 24) {
        ForEach(EchoInteractionPreview.allCases) { state in
          EchoIconButton(symbol: "gearshape", label: state.rawValue, preview: state) {}
        }
        EchoIconButton(symbol: "gearshape", label: "Không sửa timing khi đang thu") {}.disabled(
          true)
      }
    case .fields:
      EchoSearchField(placeholder: "Tìm trong bài…", text: $text)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], alignment: .leading, spacing: 16) {
        EchoTextField(
          label: "Default", text: .constant(""), placeholder: "Tìm trong bài…",
          helper: "EN / VI search")
        EchoTextField(label: "Filled", text: $text, helper: "Giữ nguyên vị trí nhãn")
        EchoTextField(
          label: "Error", text: .constant("00:12.800"),
          state: .error("End must be later than start. Keep the draft."))
        EchoTextField(
          label: "Disabled",
          text: .constant(EchoLocalization.string("Microphone unavailable", locale: locale)),
          state: .disabled("Allow microphone access to record."))
        EchoTextField(
          label: "Loading",
          text: .constant(EchoLocalization.string("Preparing transcript…", locale: locale)),
          state: .loading("Audio stays available when ready."))
        EchoTextField(
          label: "Success",
          text: .constant(EchoLocalization.string("Đã lưu bản dịch", locale: locale)),
          state: .success("Only after persistence confirms"))
        EchoTextField(
          label: "Read only",
          text: .constant(EchoLocalization.string("Audio gốc", locale: locale)), readOnly: true)
      }
      EchoSelect(
        label: "Reference accent", selection: $accent,
        options: [("uk", "English (UK)"), ("us", "English (US)")])
      VStack(spacing: 4) {
        EchoSelectOptionLabel(title: "English (UK)", selected: true, highlighted: true)
        EchoSelectOptionLabel(title: "English (US)", selected: false, highlighted: false)
      }.padding(6).background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EchoTheme.border))
    case .selections:
      HStack(spacing: 24) {
        Toggle("Off", isOn: .constant(false)).toggleStyle(EchoToggleStyle())
        Toggle("On", isOn: .constant(true)).toggleStyle(EchoToggleStyle())
        Toggle("Disabled", isOn: .constant(false)).toggleStyle(EchoToggleStyle()).disabled(true)
      }
      HStack(spacing: 24) {
        EchoCheckbox(title: "Unchecked", isOn: $on)
        EchoCheckbox(title: "Checked", isOn: .constant(true))
        EchoCheckbox(title: "Mixed", isOn: $on, isMixed: $mixed)
        EchoCheckbox(title: "Disabled", isOn: .constant(false)).disabled(true)
      }
      EchoSegmented(selection: $accent, options: [("uk", "UK"), ("us", "US")]).frame(width: 240)
      EchoSegmented(selection: $accent, options: [("uk", "Chung"), ("us", "Ghi âm & models")],
        fillsWidth: false, labelSize: 14, horizontalPadding: 20).fixedSize()
      EchoValueSlider(title: "Preview speed", value: $speed, range: 0.5...1.5)
      EchoSlider(
        value: $speed, range: 0.5...1.5, step: 0.25, label: "Focused speed", valueLabel: "0.75×",
        previewFocused: true)
      EchoChoiceGroup(
        label: "Mục tiêu luyện", selection: $choice, options: DesignSystemFixtures.choices)
    case .words:
      WordFlowLayout(spacing: 24, lineSpacing: 24) {
        ForEach(EchoWordState.allCases) { state in
          sample(state.rawValue) {
            EchoWordToken(word: "thought", ipa: "/θɔːt/", state: state, specimenWidth: 220) {}
          }
        }
        sample("Missing IPA") { EchoWordToken(word: "thought", ipa: nil, specimenWidth: 220) {} }
      }
      Text(DesignSystemFixtures.ipaGlyphs).font(EchoFont.ipa)
      Text("Tôi nghĩ điều đó đáng để thử.").font(EchoFont.translation).foregroundStyle(
        EchoTheme.secondaryText)
    case .feedback:
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 24) {
        EchoPracticeStatus(
          title: "Listening", detail: "Mic off · local audio is master", symbol: "headphones")
        EchoPracticeStatus(
          title: "Countdown  2", detail: "Mic still off · no zoom or pulse", symbol: "timer")
        EchoPracticeStatus(
          title: "Recording  00:04", detail: "Stop & save · no source audio", symbol: "mic",
          color: EchoTheme.danger)
        EchoPracticeStatus(
          title: "Saving…", detail: "Wait for a safe save, then queue", symbol: "hourglass",
          color: EchoTheme.secondaryText)
      }
      EchoInlineFeedback(
        title: "Không lưu được bản thu",
        message: "Giữ bản thu tạm. Thử lưu lại hoặc xác nhận bỏ bản thu.", tone: .error)
      EchoInlineFeedback(
        title: "Chưa phát hiện tiếng nói",
        message: "Kiểm tra micro và thu lại. Không quy đổi thành điểm 0.", tone: .warning)
      EchoInlineFeedback(
        title: "Chưa có model đánh giá",
        message: "Vẫn nghe, thu và so sánh A/B. Không tự đổi engine.", tone: .neutral)
      EchoEmptyState(
        title: "Không tìm thấy câu phù hợp",
        message: "Thử từ khóa khác hoặc xóa tìm kiếm. Câu đang luyện vẫn được giữ.",
        symbol: "magnifyingglass")
      EchoContentSkeleton()
    case .overlays:
      HStack {
        EchoButton("Thêm video") { presentation = "import" }
        EchoButton("Xóa bài") { presentation = "delete" }
        EchoButton("Giữ thay đổi timing?") { presentation = "unsaved" }
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 24) {
          ReadingSizePopover(percent: $percent)
          RepeatOptionsView(onClose: {}, initiallyExpanded: true)
        }
        VStack(alignment: .leading, spacing: 24) {
          ReadingSizePopover(percent: $percent)
          RepeatOptionsView(onClose: {}, initiallyExpanded: true)
        }
      }
    case .transport:
      PracticeTransportView(onOptions: { group = .overlays }, onReview: {}, compact: true)
      ForEach(ReadingPreviewFixtures.feedbackStates, id: \.0) { name, take in
        sample(name) { InlineTakeFeedbackRow(take: take, onReview: {}) }
      }
    }
  }

  private func sample<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      EchoLocalizedText(title).font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
      content()
    }
  }
  private func close() { presentation = nil }
}
