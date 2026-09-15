import SwiftUI

enum ReviewSignalMode: String, CaseIterable, Identifiable {
  case waveform, pitch, energy
  var id: Self { self }
  var title: String { "review.signal.\(rawValue)" }
}

/// Visual comparison of saved files. Capture and assessment remain owned by their services.
struct ReviewSignalComparisonView: View {
  @Environment(\.locale) private var locale
  let take: PracticeTake
  let runtime: ReviewRuntimePresentation
  let evidence: DeliveryEvidence?
  let onPreparePlayback: () -> Void
  var initialMode: ReviewSignalMode = .waveform
  @State private var mode: ReviewSignalMode = .waveform
  @State private var sourceContour: DeliveryTrack?
  @State private var takeContour: DeliveryTrack?
  @State private var loading = false
  @State private var error: String?
  @State private var retry = 0
  @State private var generation = 0

  private var selectedAsset: ReviewAudioAsset? { runtime.takeAssets.first { $0.id == take.id } }
  private var scale: Double {
    ReviewSignalScale.duration([runtime.sourceAsset?.duration ?? 0] + runtime.takeAssets.map(\.duration))
  }
  private struct ContourRequest: Equatable {
    let mode: ReviewSignalMode
    let evidence: DeliveryEvidence?
    let source: ReviewAudioAsset?
    let take: ReviewAudioAsset?
    let retry: Int
  }
  private var request: ContourRequest {
    .init(mode: mode, evidence: evidence, source: runtime.sourceAsset, take: selectedAsset, retry: retry)
  }
  private func takeTitle(_ item: PracticeTake) -> String {
    EchoLocalization.format("review.take", locale: locale, arguments: [item.number])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ViewThatFits(in: .horizontal) {
        HStack { title; Spacer(); tabs }
        VStack(alignment: .leading, spacing: 10) { title; tabs }
      }
      if mode == .waveform {
        if let asset = runtime.sourceAsset {
          wave(asset, title: EchoLocalization.string("Original sentence", locale: locale), source: true)
        } else { EchoNotice(text: "review.signal.source_missing") }
        if let asset = selectedAsset {
          wave(asset, title: takeTitle(take), source: false)
        } else { EchoNotice(text: "review.signal.take_missing") }
        HStack {
          Text(verbatim: "0 s")
          Spacer()
          Text(verbatim: EchoFormat.decimal(scale) + " s")
        }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        EchoLocalizedText("review.signal.wave_hint").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      } else if let source = sourceContour, let recorded = takeContour {
        DeliveryContour(source: source, take: recorded, pitch: mode == .pitch,
          sourceElapsed: elapsed(source: true), takeElapsed: elapsed(source: false))
        EchoLocalizedText(mode == .pitch ? "review.signal.pitch_hint" : "review.signal.energy_hint")
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if mode == .pitch, source.pitchFrames < 8 || recorded.pitchFrames < 8 {
          EchoNotice(text: "review.delivery.no_pitch")
        }
      } else if loading { EchoLoading(title: "review.signal.preparing") }
      else if let error {
        HStack {
          EchoNotice(text: "review.signal.failed", error: true).help(Text(verbatim: error))
          EchoButton("Retry", symbol: "arrow.clockwise") { retry += 1 }
        }
      }
      if runtime.history.count > 1 {
        EchoDisclosureGroup("review.signal.other_takes") {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(runtime.history.filter { $0.id != take.id }) { other in
              HStack(spacing: 12) {
                EchoButton(takeTitle(other), symbol: "arrow.up.left") {
                  onPreparePlayback(); runtime.onSelectTake(other.id)
                }.help(Text(verbatim: takeTitle(other)))
                if let asset = runtime.takeAssets.first(where: { $0.id == other.id }) {
                  ReviewWaveformPlot(asset: asset, scale: scale, elapsed: nil, color: EchoTheme.secondaryText)
                    .frame(height: 40)
                } else { EchoLocalizedText("review.signal.take_missing").font(EchoFont.metadata) }
                Text(verbatim: EchoFormat.decimal(other.duration) + " s")
                  .font(EchoFont.metadata).monospacedDigit()
              }
            }
          }
        }
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 14))
      .onAppear { mode = initialMode }
      .task(id: request) { await loadContours() }
  }

  private var title: some View {
    Label { EchoLocalizedText("review.signal.title") } icon: { Image(systemName: "waveform.path") }
      .font(EchoFont.heading(size: 18)).foregroundStyle(EchoTheme.text)
  }
  private var tabs: some View {
    EchoSegmented(selection: $mode, options: ReviewSignalMode.allCases.map { ($0, $0.title) },
      labelSize: 12, horizontalPadding: 10)
  }
  private func wave(_ asset: ReviewAudioAsset, title: String, source: Bool) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(verbatim: title).font(EchoFont.body(size: 13, weight: .semibold))
        if !source { EchoLocalizedText("review.signal.selected").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText) }
        Spacer()
        Text(verbatim: EchoFormat.decimal(asset.duration) + " s").font(EchoFont.metadata).monospacedDigit()
        EchoIconButton(symbol: "play.fill", label: title) {
          onPreparePlayback()
          if source { runtime.onPreviewOriginal() } else { runtime.onPreviewTake() }
        }
      }.foregroundStyle(source ? EchoTheme.accent : EchoTheme.focus)
      ReviewWaveformPlot(asset: asset, scale: scale, elapsed: elapsed(source: source),
        color: source ? EchoTheme.accent : EchoTheme.focus) { fraction in
          guard let start = ReviewSignalScale.playbackStart(fraction: fraction, scale: scale, asset: asset) else { return }
          onPreparePlayback()
          let end = Double(asset.endFrame) / Double(asset.sampleRate)
          if source { runtime.onReferenceDetail?(start, end) } else { runtime.onReplayDetail?(start, end) }
        }.frame(height: 54)
    }
  }

  private func elapsed(source: Bool) -> Double? {
    guard let player = runtime.player, [.playing, .paused].contains(player.state) else { return nil }
    if player.isSimultaneous { return source ? player.rangeElapsed : player.secondElapsed }
    let asset = source ? runtime.sourceAsset : selectedAsset
    guard let asset, player.assetURL == asset.url else { return nil }
    return max(0, player.sourceSeconds - asset.offset)
  }

  private func loadContours() async {
    generation += 1
    let current = generation
    guard mode != .waveform else { loading = false; return }
    sourceContour = nil; takeContour = nil
    error = nil; loading = true
    defer { if generation == current { loading = false } }
    do {
      // Saved neural pitch, when available, keeps its provenance. Old/unscored
      // recordings can still show local acoustic contours without being re-scored.
      if let source = evidence?.source, let recorded = evidence?.take {
        sourceContour = source; takeContour = recorded
      } else {
        guard let source = runtime.sourceAsset, let recorded = selectedAsset else {
          throw ProductionPracticeError.sourceUnavailable
        }
        let a = try await ReviewSignalAnalyzer.shared.contour(source)
        let b = try await ReviewSignalAnalyzer.shared.contour(recorded)
        try Task.checkCancellation()
        sourceContour = a; takeContour = b
      }
    } catch is CancellationError { }
    catch { if !Task.isCancelled && generation == current { self.error = error.localizedDescription } }
  }
}

struct ReviewWaveformPlot: View {
  let asset: ReviewAudioAsset
  let scale: Double
  let elapsed: Double?
  let color: Color
  var onPlay: ((Double) -> Void)? = nil
  @State private var waveform: ReviewWaveform?
  @State private var error: String?
  @State private var retry = 0

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(EchoTheme.canvas)
        if let waveform {
          Canvas { context, size in
            var path = Path()
            let peak = max(0.01, waveform.peaks.max() ?? 0)
            for (index, value) in waveform.peaks.enumerated() {
              let x = (Double(index) + 0.5) / Double(waveform.peaks.count) * waveform.duration / scale * size.width
              let amplitude = min(1, value / peak) * (size.height - 8) / 2
              path.move(to: .init(x: x, y: size.height / 2 - amplitude))
              path.addLine(to: .init(x: x, y: size.height / 2 + amplitude))
            }
            context.stroke(path, with: .color(color), lineWidth: max(1, size.width / 640 * waveform.duration / scale))
            if let elapsed, let fraction = ReviewSignalScale.fraction(time: elapsed, duration: scale) {
              var cursor = Path(); cursor.move(to: .init(x: fraction * size.width, y: 0))
              cursor.addLine(to: .init(x: fraction * size.width, y: size.height))
              context.stroke(cursor, with: .color(EchoTheme.text), lineWidth: 2)
            }
          }.accessibilityHidden(true)
          .contentShape(Rectangle())
          .onTapGesture { location in onPlay?(Double(location.x / max(1, proxy.size.width))) }
        } else if let error {
          HStack {
            EchoLocalizedText("review.signal.wave_failed").font(EchoFont.metadata).help(Text(verbatim: error))
            EchoButton("Retry", symbol: "arrow.clockwise") { retry += 1 }
          }
        } else { EchoSpinner() }
      }
    }
    .accessibilityElement(children: .contain)
    .echoAccessibilityLabel("review.signal.waveform")
    .task(id: "\(asset.hashValue):\(retry)") {
      waveform = nil; error = nil
      do {
        let result = try await ReviewSignalAnalyzer.shared.waveform(asset)
        try Task.checkCancellation(); waveform = result
      } catch is CancellationError { }
      catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}
