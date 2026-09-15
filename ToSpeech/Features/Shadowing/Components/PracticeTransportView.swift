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
  var optionsPresented: Binding<Bool> = .constant(false)
  var dictationModel: DictationModel? = nil
  @State private var optionsFromSpeed = false
  @State private var dictationSpeedPresented = false
  @State private var confirmDiscard = false

  var body: some View {
    EchoTransportBar(minimumHeight: ShadowingLayout.transportHeight * contentScale) {
      if let dictationModel { dictationControls(dictationModel) }
      else if phase.isCapture { capture }
      else if phase == .saving || phase == .saveFailed { saving }
      else if phase == .countdown { countdown }
      else { normal }
    } timeline: {
      if let model = dictationModel {
        EchoSeekSlider(value: .constant(model.player.rangeProgress * (model.sentence?.target.duration ?? 1)),
          range: 0...max(0.001, model.sentence?.target.duration ?? 1)).disabled(true)
      } else if let range = sourceSeekRange {
        EchoSeekSlider(value: sourcePositionBinding, range: range).disabled(!canSeekSource)
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

  private func dictationControls(_ model: DictationModel) -> some View {
    EchoPlaybackControls(compact: compact, scale: contentScale,
      playSymbol: model.isPlaying ? "stop.fill" : "play.fill",
      playTitle: model.isPlaying ? "Stop" : "dictation.replay",
      playEnabled: !model.isLoading && model.current != nil,
      previousEnabled: model.selectedID != model.sentences.first?.id,
      nextEnabled: model.selectedID != model.sentences.last?.id,
      playShortcut: KeyboardShortcut("r", modifiers: .command), playIdentifier: "dictation-play",
      onPrevious: { model.step(-1) },
      onPlay: { if model.isPlaying { model.stopPlayback() } else { model.listen() } },
      onNext: { model.step(1) },
      speedTitle: "\(EchoFormat.decimal(model.speed))×",
      speedSubtitle: model.player.state == .preparing ? "playback.r3.preparing" : model.speed < 1 ? (compact ? "R3" : "Rubber Band R3") : "Tốc độ nghe",
      speedEnabled: !model.isPlaying, speedOptionsPresented: $dictationSpeedPresented,
      onSpeedOptions: { dictationSpeedPresented = true }) {
        VStack(alignment: .leading, spacing: 8) {
          EchoLocalizedText("Playback speed").font(EchoFont.body(size: 14, weight: .semibold))
          ForEach([0.5, 0.75, 1.0], id: \.self) { speed in
            EchoRowButton(selected: model.speed == speed, action: {
              model.speed = speed; dictationSpeedPresented = false
            }) { Text("\(EchoFormat.decimal(speed))×") }
          }
        }.padding(16).frame(width: 220)
      } status: {
        VStack(alignment: .leading, spacing: 6) {
          EchoLocalizedText(model.player.state == .preparing ? "dictation.audio_preparing" : model.phaseKey)
            .font(EchoFont.body(size: 14, weight: .semibold))
          EchoLocalizedText(model.phase == .result ? "dictation.result_replay_hint" : "dictation.replay_hint")
            .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
      } actions: {
        if model.phase == .paused {
          EchoButton("dictation.resume", symbol: "play", action: model.resume)
        } else if model.phase == .result {
          EchoButton("Next sentence", symbol: "arrow.right") { model.step(1) }
            .disabled(model.selectedID == model.sentences.last?.id)
        } else {
          EchoButton("dictation.pause", symbol: "pause", action: model.suspend)
            .disabled(model.phase == .ready)
        }
      }
  }

  private var normal: some View {
    @Bindable var store = store
    return EchoPlaybackControls(compact: compact, scale: contentScale,
      playSymbol: phase == .listening ? "pause.fill" : "play.fill",
      playTitle: phase == .listening ? "Tạm dừng nghe" : "Nghe mẫu",
      previousEnabled: canMove(-1), nextEnabled: canMove(1),
      onPrevious: { move(-1) }, onPlay: toggleListen, onNext: { move(1) },
      speedTitle: "\(EchoFormat.decimal(store.preferences.speed))×", speedSubtitle: playbackSubtitle,
      speedOptionsPresented: optionsBinding(fromSpeed: true),
      onSpeedOptions: { optionsFromSpeed = true; onOptions() }) {
        repeatOptions
      } status: {
      VStack(alignment: .leading, spacing: 8) {
        EchoTransportOptionsButton(title: repeatLabel, scale: contentScale,
          action: { optionsFromSpeed = false; onOptions() })
          .popover(isPresented: optionsBinding(fromSpeed: false), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            repeatOptions
          }
        Toggle(isOn: $store.preferences.autoRecord) {
          EchoLocalizedText(
            store.preferences.autoRecord
              ? "Thu tự động đã bật · Mic tắt" : "Thu tự động tắt · Mic tắt"
          ).font(EchoFont.body(size: 13 * contentScale)).foregroundStyle(EchoTheme.secondaryText)
        }
        .toggleStyle(EchoToggleStyle(minimumHeight: 20))
      }
      } actions: {
      HStack(spacing: 8) {
        if phase != .listening {
          if compact {
            EchoIconButton(
              symbol: "mic", label: hasListened ? "Thu âm" : "Thu ngay", size: .prominent
            ) { record() }
              .accessibilityIdentifier("record-take")
          } else {
            EchoButton(hasListened ? "Thu âm" : "Thu ngay", symbol: "mic", size: .prominent) {
              record()
            }
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

  private var playbackSubtitle: String {
    guard let productionModel else { return "Tốc độ nghe" }
    if productionModel.reviewPlayer.isPreparing { return "playback.r3.preparing" }
    return store.preferences.speed < 1 ? (compact ? "R3" : "Rubber Band R3") : "Tốc độ nghe"
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
        Text(hasListened ? "Source finished · microphone still off" : "Source stopped · microphone still off")
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
      if let productionModel {
        LivePitchEnergyTrace(
          reference: productionModel.controller.referenceDeliveryTrack,
          live: productionModel.controller.liveDeliveryTrack,
          elapsed: elapsed,
          sentenceDuration: productionModel.controller.currentTargetDuration)
          .frame(height: 66 * contentScale)
      } else {
        inputMeter   // preview route keeps the simple capsule meter
      }
      HStack(alignment: .center, spacing: 24) {
        Image(systemName: "mic").font(.system(size: 24)).foregroundStyle(EchoTheme.danger)
          .frame(width: 40, height: 42).accessibilityHidden(true)
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
    if dictationModel != nil { return EchoCopy("dictation.replay_hint") }
    if let model = productionModel {
      return model.controller.error.map(\.presentationCopy)
        ?? EchoCopy("Native source audio and microphone recording")
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

  private func optionsBinding(fromSpeed: Bool) -> Binding<Bool> {
    Binding(get: { optionsPresented.wrappedValue && optionsFromSpeed == fromSpeed },
      set: { if optionsFromSpeed == fromSpeed { optionsPresented.wrappedValue = $0 } })
  }

  private var repeatOptions: some View {
    RepeatOptionsView(onClose: { optionsPresented.wrappedValue = false })
      .environment(store)
      .environment(\.locale, store.preferences.language.locale)
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
}
