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
  /// Present only where the transcript may lose a word (production lessons, not previews).
  var onRemoveWord: ((String) -> Void)? = nil
  var onPreviewSource: (() -> Void)? = nil
  var onPreviewReference: ((LessonWord, ReferenceAccent) -> Void)? = nil
  var usesPreviewReferenceAudio = true
  var referenceUsesAppleVoice = false
  var referencePlayingAccent: ReferenceAccent? = nil
  var referenceErrorKey: String? = nil
  var runtime: WordPronunciationRuntime? = nil
  @Environment(EchoStore.self) private var store
  @State private var confirmingRemoval = false

  var body: some View {
    EchoModalLayout(width: 520, referenceHeight: 526) {
      HStack {
        EchoLocalizedText("Word Pronunciation").font(EchoFont.body(size: 16, weight: .semibold))
        Spacer()
        EchoButton("Đóng", symbol: "xmark", action: onClose)
          .keyboardShortcut(.cancelAction)
      }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
    } content: {
      VStack(alignment: .leading, spacing: 20) {
        if let word {
          VStack(alignment: .leading, spacing: 12) {
            Text(word.text).font(EchoFont.heading(size: 36, weight: .semibold))
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if IPAFormatting.isPronounceable(word.text) {
              HStack(alignment: .top, spacing: 20) {
                referencePronunciation(word, accent: .uk)
                referencePronunciation(word, accent: .us)
              }
            }
            if let referenceErrorKey {
              EchoNotice(text: referenceErrorKey, error: true)
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            EchoLocalizedText("Giọng trong video").font(EchoFont.body(size: 14, weight: .semibold))
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
            EchoLocalizedText(
              word.span == nil
                ? "Chưa có timing chính xác · nghe cả ngữ cảnh."
                : word.needsTimingReview ? "timing.observed.review" : "Vòng lặp đã tạm dừng."
            )
            .font(EchoFont.metadata).foregroundStyle(
              word.span == nil || word.needsTimingReview ? EchoTheme.caution : EchoTheme.secondaryText)
            Text(sentence.text).font(EchoFont.body(size: 13)).foregroundStyle(
              EchoTheme.secondaryText)
            if !sentence.translation.isEmpty {
              Text(sentence.translation).font(EchoFont.body(size: 13)).foregroundStyle(
                EchoTheme.secondaryText)
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        } else {
          EchoNotice(text: "Từ không còn trong phiên bản câu này.", error: true)
        }
      }.padding(.horizontal, 24)
    } footer: {
      VStack(spacing: 20) {
        Divider().overlay(EchoTheme.separator)
        HStack {
          EchoLocalizedText("Timing từ chưa đúng?").font(EchoFont.body(size: 13)).foregroundStyle(
            EchoTheme.secondaryText)
          Spacer()
          if onRemoveWord != nil {
            EchoButton("word.remove", symbol: "trash", size: .regular) { confirmingRemoval = true }
              .disabled(word == nil)
          }
          EchoButton("Chỉnh timing", symbol: "slider.horizontal.3", size: .regular) {
            onEditTiming(wordID)
          }.disabled(word == nil)
        }
      }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
    }
      .confirmationDialog("word.remove.title", isPresented: $confirmingRemoval) {
        Button("word.remove", role: .destructive) { onRemoveWord?(wordID) } // native-control: confirmation
        Button("Hủy", role: .cancel) {} // native-control: confirmation
      } message: {
        EchoLocalizedText("word.remove.message")
      }
      .background(EchoTheme.raised).foregroundStyle(EchoTheme.text)
      .environment(\.locale, store.preferences.language.locale)
      .preferredColorScheme(.dark)
      .onExitCommand(perform: onClose)
      .disabled(
        runtime?.interactionDisabled
          ?? (store.practice.phase.isCapture || store.practice.phase == .saving
            || store.practice.phase == .saveFailed))
  }
  private func referencePronunciation(_ word: LessonWord, accent: ReferenceAccent) -> some View {
    let ipa = IPAFormatting.display(word.ipa(for: accent))
    let canPlay = IPAFormatting.isPronounceable(word.text)
      && (usesPreviewReferenceAudio || onPreviewReference != nil)
    return VStack(alignment: .leading, spacing: 6) {
      EchoLocalizedText(accent == .uk ? "word.accent.uk" : "word.accent.us")
        .font(EchoFont.body(size: 12, weight: .medium)).foregroundStyle(EchoTheme.secondaryText)
      HStack(alignment: .center, spacing: 8) {
        Group {
          if let ipa { Text(verbatim: ipa) }
          else { EchoLocalizedText("Chưa có IPA") }
        }
        .font(EchoFont.body(size: ipa == nil ? 14 : 24)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        EchoIconButton(symbol: referencePlayingAccent == accent ? "stop.fill" : "speaker.wave.2",
          label: referencePlayingAccent == accent ? "word.reference.stop"
            : accent == .uk ? "word.reference.uk" : "word.reference.us") {
            if let onPreviewReference { onPreviewReference(word, accent) }
            else if usesPreviewReferenceAudio {
              store.practice.previewReference(word: word, accent: accent)
            }
          }
          .disabled(!canPlay)
          .echoHelp(canPlay
            ? (referencePlayingAccent == accent ? "word.reference.stop"
              : accent == .uk ? "word.reference.uk" : "word.reference.us")
            : "word.reference.unavailable")
      }
      if referenceUsesAppleVoice {
        EchoLocalizedText("word.reference.apple")
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var word: LessonWord? { sentence.words.first { $0.id == wordID } }
}
