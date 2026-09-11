import SwiftUI

/// One approved transport renderer. Preview and production provide different
/// state/action adapters, but they do not own separate visual trees.
struct PracticeTransportView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var onOptions: () -> Void
  var onReview: () -> Void
  var compact = false
  var contentScale: CGFloat = 1
  var productionModel: ProductionShadowingModel? = nil
  @State private var confirmDiscard = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if phase.isCapture { capture }
      else if phase == .saving || phase == .saveFailed { saving }
      else if phase == .countdown { countdown }
      else { normal }
    }
    .padding(.horizontal, 24).padding(.vertical, 20)
    .frame(
      maxWidth: .infinity, minHeight: ShadowingLayout.transportHeight * contentScale,
      alignment: .leading)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    .foregroundStyle(EchoTheme.text)
    .overlay(alignment: .top) {
      if let range = sourceSeekRange {
        EchoSeekSlider(value: sourcePositionBinding, range: range)
          .disabled(!canSeekSource)
          .padding(.horizontal, 24)
      }
    }
    .echoHelp(helpCopy)
    .alert("Discard this take?", isPresented: $confirmDiscard) {
      Button("Keep take", role: .cancel) {} // native-control: confirmation
      Button("Discard take", role: .destructive) { discardPending() } // native-control: confirmation
    } message: {
      EchoLocalizedText(
        productionModel == nil
          ? "Only the current unsaved preview take will be discarded. Earlier takes stay in history."
          : "Only the current unsaved take will be discarded. Earlier takes stay in history.")
    }
  }

  private var normal: some View {
    @Bindable var store = store
    return HStack(spacing: compact ? 12 : 24) {
      HStack(spacing: compact ? 8 : 12) {
        transportIcon("backward.end", label: "Previous sentence") { move(-1) }
          .disabled(!canMove(-1))
        EchoTransportButton(
          symbol: phase == .listening ? "pause.fill" : "play.fill",
          title: phase == .listening ? "Tạm dừng nghe" : "Nghe mẫu",
          width: 54 * contentScale, height: 54 * contentScale, primary: true, circular: true
        ) { toggleListen() }
        .accessibilityIdentifier("play-loop")
        transportIcon("forward.end", label: "Next sentence") { move(1) }
          .disabled(!canMove(1))
      }
      EchoTransportOptionsButton(
        title: "\(EchoFormat.decimal(store.preferences.speed))×", subtitle: "Tốc độ nghe",
        scale: contentScale, action: onOptions)
        .frame(width: compact ? 84 : 116 * contentScale, alignment: .leading)
        .help("Playback and repeat options")
      Rectangle().fill(EchoTheme.border).frame(width: 1, height: 44)
      VStack(alignment: .leading, spacing: 8) {
        EchoTransportOptionsButton(title: repeatLabel, scale: contentScale, action: onOptions)
        Toggle(isOn: $store.preferences.autoRecord) {
          EchoLocalizedText(
            store.preferences.autoRecord
              ? "Thu tự động đã bật · Mic tắt" : "Thu tự động tắt · Mic tắt"
          ).font(EchoFont.body(size: 13 * contentScale)).foregroundStyle(EchoTheme.secondaryText)
        }
        .toggleStyle(EchoToggleStyle(minimumHeight: 20))
      }
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        if phase != .listening && hasListened {
          if compact {
            EchoIconButton(symbol: "mic", label: "Thu âm", size: .prominent) { record() }
              .accessibilityIdentifier("record-take")
          } else {
            EchoButton("Thu âm", symbol: "mic", size: .prominent) { record() }
              .accessibilityIdentifier("record-take")
          }
        }
        EchoTransportButton(
          symbol: phase == .listening ? "pause" : "play",
          title: phase == .listening
            ? (compact ? "Tạm dừng" : "Tạm dừng vòng")
            : canResumeSource && isRepeating ? "Tiếp tục vòng" : "Bắt đầu vòng",
          width: compact ? 124 : (phase == .listening ? 178 : phase == .paused ? 165 : 156) * contentScale,
          height: 52 * contentScale, primary: true
        ) { toggleRepeat() }
      }
    }
  }

  private var saving: some View {
    HStack(spacing: 16) {
      if phase == .saving { EchoSpinner() }
      VStack(alignment: .leading, spacing: 6) {
        EchoLocalizedText(phase.title).font(EchoFont.body(size: 17, weight: .medium))
        EchoLocalizedText(
          phase == .saving
            ? (productionModel == nil
              ? "Microphone off · simulated save" : "Microphone off · saving this take")
            : (productionModel == nil
              ? "The preview take is retained. Retry or explicitly discard it."
              : "The recorded take is retained. Retry or explicitly discard it."))
          .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
      }
      Spacer()
      if phase == .saveFailed {
        EchoButton("Discard", kind: .secondary) { confirmDiscard = true }
        EchoButton("Retry save", symbol: "arrow.clockwise", kind: .primary) { retrySave() }
      }
    }
  }

  private var countdown: some View {
    HStack(spacing: 24) {
      Text("\(max(1, Int(ceil(remaining))))")
        .font(EchoFont.body(size: 40, weight: .medium, design: .rounded))
        .foregroundStyle(EchoTheme.accent)
      VStack(alignment: .leading, spacing: 6) {
        Text("Your turn in a moment").font(EchoFont.body(size: 17, weight: .medium))
        Text("Source finished · microphone still off")
          .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
      }
      Spacer()
      EchoButton("Pause", symbol: "pause") { pause() }
      EchoButton("Cancel recording", symbol: "xmark", kind: .secondary) {
        cancelCountdown()
      }
    }
  }

  private var capture: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Circle().fill(EchoTheme.danger).frame(width: 8, height: 8)
        EchoLocalizedText(phase.title).font(EchoFont.body(size: 17, weight: .medium))
        Spacer()
        Text(EchoFormat.decimal(elapsed) + "s")
          .font(EchoFont.body(size: 18, design: .monospaced))
      }
      HStack(alignment: .center, spacing: 24) {
        Image(systemName: "mic").font(.system(size: 24)).foregroundStyle(EchoTheme.danger)
          .frame(width: 40, height: 42).accessibilityHidden(true)
        inputMeter
        Text(verbatim: captureDetail)
          .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.secondaryText)
        Spacer()
        EchoButton("Pause & keep", symbol: "pause") { pause() }
        EchoButton("Done", symbol: "checkmark", kind: .primary) { finishRecording() }
          .accessibilityIdentifier("finish-take")
      }
      HStack {
        EchoButton("Discard take", kind: .danger) { confirmDiscard = true }
        Spacer()
        Text("Source audio is stopped · each round saves separately")
          .font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.secondaryText)
      }
    }
  }

  private var phase: PracticePhase { productionModel?.controller.phase ?? store.practice.phase }
  private var remaining: Double { productionModel?.controller.remaining ?? store.practice.remaining }
  private var elapsed: Double { productionModel?.controller.elapsed ?? store.practice.elapsed }
  private var hasListened: Bool { productionModel?.controller.hasListened ?? store.practice.hasListened }
  private var currentRound: Int { productionModel?.controller.round ?? store.practice.round }
  private var isRepeating: Bool {
    productionModel?.controller.isRepeating ?? store.practice.isRepeating
  }
  private var canResumeSource: Bool { productionModel?.controller.canResumeSource ?? false }
  private var canSeekSource: Bool {
    productionModel?.controller.canSeekSource
      ?? [.idle, .paused, .listening, .feedback].contains(phase)
  }
  private var sourceSeekRange: ClosedRange<Double>? {
    if let value = productionModel?.controller.sourceSeekRange { return value }
    guard let value = store.practice.sourceSeekRange else { return nil }
    return value.start...value.end
  }
  private var sourcePositionBinding: Binding<Double> {
    Binding(
      get: {
        guard let range = sourceSeekRange else { return 0 }
        let value = productionModel?.controller.sourcePosition ?? store.practice.sourcePosition
        return min(range.upperBound, max(range.lowerBound, value))
      },
      set: { value in
        if let model = productionModel { model.controller.seekSource(to: value) }
        else { store.practice.seekSource(to: value) }
      })
  }
  private var repeatLabel: String {
    if hasListened && phase != .listening && phase != .paused {
      return EchoLocalization.format(
        "transport.listened_repeat", locale: locale, arguments: [store.preferences.repeats])
    }
    let state = phase == .listening ? "Đang nghe" : phase == .paused ? "Tạm dừng" : "Sẵn sàng"
    return EchoLocalization.format(
      "transport.round", locale: locale,
      arguments: [currentRound, store.preferences.repeats,
        EchoLocalization.string(state, locale: locale)])
  }
  private var captureDetail: String {
    if phase == .trailingSilence {
      return EchoLocalization.format(
        "transport.finishing_in", locale: locale,
        arguments: [EchoFormat.decimal(max(0, remaining))])
    }
    return productionModel == nil
      ? EchoLocalization.string("Preview microphone · no audio is captured", locale: locale)
      : EchoLocalization.string("Microphone recording · source audio is stopped", locale: locale)
  }
  private var helpCopy: EchoCopy {
    if let model = productionModel {
      return model.controller.error.map {
        EchoCopy("storage.detail", arguments: [.raw($0.localizedDescription)])
      } ?? EchoCopy("Native source audio and microphone recording")
    }
    return store.practice.lastPreview
      ?? EchoCopy("Source audio and recording are simulated in this UI preview.")
  }

  private var inputMeter: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(EchoTheme.border)
        Capsule().fill(EchoTheme.danger)
          .frame(width: proxy.size.width * inputLevel)
      }
    }
    .frame(width: compact ? 72 : 100, height: 8)
    .echoAccessibilityLabel("Microphone input level")
    .accessibilityValue(Text(inputLevel, format: .percent.precision(.fractionLength(0))))
  }
  private var inputLevel: CGFloat {
    guard let model = productionModel else {
      return phase == .awaitingSpeech ? 0.08 : phase == .recording ? 0.7 : 0.22
    }
    return CGFloat(max(0, min(1, (Double(model.controller.inputLevelDB) + 60) / 60)))
  }

  private func toggleListen() {
    if phase == .listening { pause() }
    else if let model = productionModel {
      if model.controller.canResumeSource && !model.controller.isRepeating { model.resumeSource() }
      else { model.listen() }
    } else { store.practice.playSentence() }
  }
  private func toggleRepeat() {
    if phase == .listening { pause() }
    else if let model = productionModel {
      if model.controller.canResumeSource && model.controller.isRepeating { model.resumeSource() }
      else { model.listenLoop() }
    } else { store.practice.playSentence(repeating: true) }
  }
  private func pause() {
    if let model = productionModel { model.pause() } else { _ = store.practice.interrupt() }
  }
  private func record() {
    if let model = productionModel { model.record() } else { store.practice.requestRecord() }
  }
  private func cancelCountdown() {
    if let model = productionModel { model.cancelCountdown() }
    else { store.practice.cancelCountdown() }
  }
  private func finishRecording() {
    if let model = productionModel { model.finishRecording() } else { store.practice.finishRecording() }
  }
  private func retrySave() {
    if let model = productionModel { model.retrySave() } else { store.practice.retrySave() }
  }
  private func discardPending() {
    if let model = productionModel { model.discardPending() } else { store.practice.discardPending() }
  }
  private func canMove(_ delta: Int) -> Bool {
    if let model = productionModel { return model.canSelectRelative(delta) }
    guard let lesson = store.selectedLesson,
      let index = lesson.sentences.firstIndex(where: { $0.id == store.selectedSentenceID })
    else { return false }
    return lesson.sentences.indices.contains(index + delta)
  }
  private func move(_ delta: Int) {
    if let model = productionModel { model.selectRelative(delta); return }
    guard let lesson = store.selectedLesson,
      let index = lesson.sentences.firstIndex(where: { $0.id == store.selectedSentenceID }),
      lesson.sentences.indices.contains(index + delta)
    else { return }
    store.selectSentence(lesson.sentences[index + delta].id)
  }
  private func transportIcon(_ symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    EchoTransportButton(
      symbol: symbol, title: label, width: compact ? 32 : 40,
      height: 44, circular: true, action: action)
  }
}
