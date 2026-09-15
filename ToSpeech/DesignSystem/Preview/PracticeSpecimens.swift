import SwiftUI

struct PracticeSpecimens: View {
  @State private var selectedWord: String?
  @State private var showIPA = true
  @State private var showTranslation = true

  var body: some View {
    SpecimenSection(title: "Playback · component dùng chung") {
      EchoTransportBar {
        EchoPlaybackControls(playSymbol: "play.fill", playTitle: "Nghe mẫu",
          previousEnabled: false, nextEnabled: true,
          onPrevious: {}, onPlay: {}, onNext: {}, speedTitle: "0.75×", speedSubtitle: "Rubber Band R3",
          speedOptionsPresented: .constant(false), onSpeedOptions: {}) {
            EmptyView()
          } status: { EchoLocalizedText("dictation.ready") }
          actions: { EchoButton("dictation.pause") {} }
      } timeline: { EchoSeekSlider(value: .constant(0.4), range: 0...1).disabled(true) }
    }
    SpecimenSection(title: "Câu · IPA · dịch") {
      HStack {
        Toggle("IPA", isOn: $showIPA).toggleStyle(EchoToggleStyle())
        Toggle("Bản dịch", isOn: $showTranslation).toggleStyle(EchoToggleStyle())
        Spacer()
        EchoStatusBadge(title: "Ví dụ UI", tone: .neutral)
      }
      WordFlowLayout(spacing: 4, lineSpacing: 12) {
        ForEach(DesignSystemFixtures.sentence, id: \.0) { word, ipa in
          EchoWordToken(
            word: word, ipa: ipa, state: selectedWord == word ? .selected : .normal,
            showIPA: showIPA
          ) {
            selectedWord = word
          }
        }
      }
      if showTranslation {
        Text(DesignSystemFixtures.translation).font(EchoFont.translation).foregroundStyle(
          EchoTheme.secondaryText)
      }
      Text("Chọn từ để thử highlight. Mẫu này không phát audio.").font(EchoFont.metadata)
        .foregroundStyle(EchoTheme.secondaryText)
    }
    SpecimenSection(title: "WordIPA · các trạng thái") {
      WordFlowLayout(spacing: 16) {
        ForEach(EchoWordState.allCases) { state in
          VStack(spacing: 8) {
            EchoWordToken(word: "thought", ipa: "/θɔːt/", state: state) {}
            EchoLocalizedText(state.rawValue).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          }
        }
        EchoWordToken(word: "unknown", ipa: nil) {}
      }
      EchoInlineFeedback(
        title: "Cần chỉnh timing",
        message: "Từ chưa có mốc chắc chắn. Nghe trong ngữ cảnh để tránh cắt mất âm.",
        tone: .warning)
    }
    SpecimenSection(title: "Trạng thái nghe → thu") {
      HStack {
        EchoStatusBadge(title: "Đang nghe · Mic tắt", tone: .info)
        EchoStatusBadge(title: "Chuẩn bị thu · 3", tone: .neutral)
      }
      HStack {
        EchoStatusBadge(title: "Đang thu · 00:04", tone: .error, symbol: "mic.fill")
        EchoStatusBadge(title: "Đã lưu lượt thu", tone: .success)
      }
      EchoLoading(title: "Đang lưu lượt thu…")
      Text("Mẫu trạng thái tĩnh. Engine audio, micro và đánh giá vẫn dùng preview hiện có.")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
    }
  }
}

struct FeedbackSpecimens: View {
  @State private var retried = false
  var body: some View {
    SpecimenSection(title: "Thông báo có ngữ cảnh") {
      EchoInlineFeedback(
        title: "Đang nghe trong ngữ cảnh", message: "Chưa xác định được ranh giới riêng của từ này."
      )
      EchoInlineFeedback(
        title: "Không có tiếng nói", message: "Kiểm tra đầu vào micro và thử thu lại.",
        tone: .warning)
      EchoInlineFeedback(
        title: retried ? "Đã gửi yêu cầu thử lại" : "Chưa lưu được lượt thu",
        message: retried
          ? "Mẫu giao diện — chưa có thao tác ghi âm thật."
          : "Lượt thu vẫn được giữ. Kiểm tra dung lượng trống rồi thử lại.",
        tone: retried ? .info : .error, actionTitle: "Thử lại"
      ) { retried = true }
      EchoInlineFeedback(
        title: "Đã lưu timing", message: "Các chỉnh sửa thủ công được giữ riêng.", tone: .success)
    }
    SpecimenSection(title: "Loading · tiến trình · skeleton") {
      EchoLoading(title: "Đang chuẩn bị transcript…")
      EchoLoading(title: "Đang tải gói · số liệu minh họa", fraction: 0.42)
      VStack(alignment: .leading, spacing: 10) {
        EchoSkeleton(height: 20).frame(width: 240)
        EchoSkeleton().frame(maxWidth: 480)
        EchoSkeleton().frame(maxWidth: 360)
      }.accessibilityElement(children: .ignore).accessibilityLabel("Đang tải nội dung")
    }
    SpecimenSection(title: "Empty state") {
      EchoEmptyState(
        title: "Chưa có bài luyện", message: "Thêm một video để bắt đầu nghe từng câu.",
        symbol: "rectangle.stack")
      EchoButton("Thêm video", symbol: "plus", kind: .primary) { retried = false }
    }
  }
}
