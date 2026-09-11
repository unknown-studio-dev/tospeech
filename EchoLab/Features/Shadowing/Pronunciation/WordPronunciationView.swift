import SwiftUI

struct WordPronunciationRuntime {
  var previewSpeed: Binding<Double>
  var interactionDisabled: Bool
}

struct WordPronunciationView: View {
  let sentence: LessonSentence
  let wordID: String
  let onEditTiming: (String) -> Void
  let onClose: () -> Void
  var onPreviewSource: (() -> Void)? = nil
  var onPreviewReference: ((LessonWord, ReferenceAccent) -> Void)? = nil
  var usesPreviewReferenceAudio = true
  var runtime: WordPronunciationRuntime? = nil
  @Environment(EchoStore.self) private var store
  @State private var accent: ReferenceAccent = .uk

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Word Pronunciation").font(EchoFont.body(size: 16, weight: .semibold))
        Spacer()
        EchoButton("Đóng", symbol: "xmark", action: onClose)
          .keyboardShortcut(.cancelAction)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let word {
            Text(word.text).font(EchoFont.heading(size: 36, weight: .semibold))
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
              Text("Giọng trong video").font(EchoFont.body(size: 14, weight: .semibold))
              HStack {
                EchoButton(
                  word.span == nil ? "Nghe trong ngữ cảnh" : "Nghe lại audio gốc",
                  symbol: "speaker.wave.2", kind: .primary, size: .regular
                ) {
                  if let onPreviewSource { onPreviewSource() }
                  else { store.practice.previewWord(sentence: sentence, wordID: word.id) }
                }
                Spacer(minLength: 0)
                EchoSelect(
                  label: "Tốc độ nghe từ",
                  selection: Binding(
                    get: { String(runtime?.previewSpeed.wrappedValue ?? store.practice.previewSpeed) },
                    set: {
                      guard let speed = Double($0) else { return }
                      if let runtime { runtime.previewSpeed.wrappedValue = speed }
                      else { store.practice.previewSpeed = speed }
                    }),
                  options: PracticeOptions.speeds.map { (String($0), "\(EchoFormat.decimal($0))×") }
                )
                .frame(width: 100)
              }
              Text(
                word.span == nil
                  ? "Chưa có timing chính xác · nghe cả ngữ cảnh." : "Vòng lặp đã tạm dừng."
              )
              .font(EchoFont.metadata).foregroundStyle(
                word.span == nil ? EchoTheme.caution : EchoTheme.secondaryText)
              Text(sentence.text).font(EchoFont.body(size: 13)).foregroundStyle(
                EchoTheme.secondaryText)
              if !sentence.translation.isEmpty {
                Text(sentence.translation).font(EchoFont.body(size: 13)).foregroundStyle(
                  EchoTheme.secondaryText)
              }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
              .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Phát âm tham khảo").font(EchoFont.body(size: 14, weight: .semibold))
                Spacer()
                ForEach(ReferenceAccent.allCases, id: \.self) { value in
                  EchoButton(value.rawValue, kind: accent == value ? .primary : .secondary) {
                    accent = value
                  }
                  .accessibilityAddTraits(accent == value ? .isSelected : [])
                }
              }
              HStack {
                Group {
                  if let ipa = word.ipa(for: accent) { Text(verbatim: ipa) }
                  else { EchoLocalizedText("Chưa có IPA") }
                }.font(EchoFont.body(size: 28)).textSelection(.enabled)
                Spacer()
                EchoButton("Nghe tham khảo", symbol: "speaker.wave.2", size: .regular) {
                  if let onPreviewReference { onPreviewReference(word, accent) }
                  else if usesPreviewReferenceAudio {
                    store.practice.previewReference(word: word, accent: accent)
                  }
                }
                .disabled(!usesPreviewReferenceAudio && onPreviewReference == nil)
              }
              Text("UK/US chỉ đổi IPA và giọng tham khảo, không đổi audio gốc.")
                .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
            }
          } else {
            EchoNotice(text: "Từ không còn trong phiên bản câu này.", error: true)
          }
        }
      }.scrollIndicators(.visible)
      Divider().overlay(EchoTheme.separator)
      HStack {
        Text("Timing từ chưa đúng?").font(EchoFont.body(size: 13)).foregroundStyle(
          EchoTheme.secondaryText)
        Spacer()
        EchoButton("Chỉnh timing", symbol: "slider.horizontal.3", size: .regular) {
          onEditTiming(wordID)
        }.disabled(word == nil)
      }
    }.padding(24).frame(width: 520, height: 526)
      .background(EchoTheme.raised).foregroundStyle(EchoTheme.text)
      .preferredColorScheme(.dark).onAppear { accent = store.preferences.accent }
      .onExitCommand(perform: onClose)
      .disabled(
        runtime?.interactionDisabled
          ?? (store.practice.phase.isCapture || store.practice.phase == .saving
            || store.practice.phase == .saveFailed))
  }
  private var word: LessonWord? { sentence.words.first { $0.id == wordID } }
}
