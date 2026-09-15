import SwiftUI

enum DeliveryDimension: String, CaseIterable, Identifiable {
  case stress, rhythm, intonation, linking
  var id: String { rawValue }
  var title: String { "review.delivery.\(rawValue)" }
  var symbol: String {
    switch self { case .stress: "waveform"; case .rhythm: "timer"; case .intonation: "chart.xyaxis.line"; case .linking: "link" }
  }
}

struct DeliveryComparisonView: View {
  @Environment(\.locale) private var locale
  @Binding var dimension: DeliveryDimension
  let evidence: DeliveryEvidence?
  let sourceOffset: Double
  var showsNavigation = true
  let onCompare: (AudioSpan, AudioSpan) -> Void
  private func copy(_ key: String) -> String { EchoLocalization.string(key, locale: locale) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if showsNavigation {
        EchoSegmented(selection: $dimension, options: DeliveryDimension.allCases.map { ($0, $0.title) },
          labelSize: 12, horizontalPadding: 6)
      } else { EchoLocalizedText(dimension.title).font(EchoFont.heading(size: 18)) }
      if let source = evidence?.source, let take = evidence?.take {
        if dimension == .intonation || dimension == .stress {
          let pitch = dimension == .intonation
          if !pitch || (source.pitchFrames >= 8 && take.pitchFrames >= 8) {
            DeliveryContour(source: source, take: take, pitch: pitch)
          } else { EchoNotice(text: "review.delivery.no_pitch") }
        }
        switch dimension {
        case .intonation: EmptyView()
        case .stress:
          EchoLocalizedText("review.delivery.stress_hint")
          if let words = evidence?.words, !words.isEmpty {
            ForEach(Array(words.sorted { abs($0.takeDB-$0.sourceDB) > abs($1.takeDB-$1.sourceDB) }.prefix(2))) { word in
              HStack {
                Text(verbatim: word.text).fontWeight(.semibold)
                Spacer()
                Text(verbatim: String(format: "%+.1f dB", word.takeDB-word.sourceDB)).monospacedDigit()
                EchoIconButton(symbol: "headphones", label: "A → B") { compare(word.source, word.take) }
              }
            }
          }
        case .rhythm:
          metric("review.delivery.duration", source.activeDuration.map { EchoFormat.decimal($0) } ?? "—",
            take.activeDuration.map { EchoFormat.decimal($0) } ?? "—", unit: "s")
          metric("review.delivery.pauses", "\(source.pauses.count)", "\(take.pauses.count)")
          metric("review.delivery.silence", EchoFormat.decimal(source.pauses.reduce(0) { $0+$1.duration }),
            EchoFormat.decimal(take.pauses.reduce(0) { $0+$1.duration }), unit: "s")
          EchoLocalizedText("review.delivery.rhythm_hint")
        case .linking:
          EchoLocalizedText("review.delivery.linking_hint")
          if let boundaries = evidence?.boundaries, !boundaries.isEmpty {
            ForEach(Array(boundaries.sorted { $0.takePause-$0.sourcePause > $1.takePause-$1.sourcePause }.prefix(3))) { boundary in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(verbatim: boundary.phrase).fontWeight(.semibold)
                  Spacer()
                  EchoIconButton(symbol: "headphones", label: "A → B") { compare(boundary.source, boundary.take) }
                }
                Text(verbatim: "\(copy("Original sentence")): \(EchoFormat.decimal(boundary.sourcePause))s · \(copy("Your full take")): \(EchoFormat.decimal(boundary.takePause))s")
                  .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
              }
            }
          } else { EchoNotice(text: "review.delivery.no_boundaries") }
        }
        EchoButton("review.delivery.compare_sentence", symbol: "headphones") {
          compare(.init(start: 0, end: source.duration), .init(start: 0, end: take.duration))
        }
        EchoDisclosureGroup("review.delivery.about") {
          if dimension == .intonation { EchoLocalizedText(evidence?.pitchModel == nil ? "review.delivery.pitch_hint" : "assessment.uk.pitch_model") }
          EchoLocalizedText("review.delivery.measured_hint")
        }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      } else {
        EchoNotice(text: evidence?.error == nil ? "review.delivery.missing" : "review.delivery.failed",
          error: evidence?.error != nil)
        if let error = evidence?.error {
          Text(verbatim: copy(error)).font(EchoFont.metadata).textSelection(.enabled)
        }
      }
    }.font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.text)
  }
  private func metric(_ key: String, _ source: String, _ take: String, unit: String = "") -> some View {
    HStack {
      EchoLocalizedText(key).frame(maxWidth: .infinity, alignment: .leading)
      Text(verbatim: source + unit).foregroundStyle(EchoTheme.accent).frame(width: 70, alignment: .trailing)
      Text(verbatim: take + unit).foregroundStyle(EchoTheme.focus).frame(width: 70, alignment: .trailing)
    }.monospacedDigit().padding(.vertical, 5)
      .accessibilityLabel("\(copy(key)): \(copy("Original sentence")) \(source)\(unit), \(copy("Your full take")) \(take)\(unit)")
  }
  private func compare(_ source: AudioSpan, _ take: AudioSpan) {
    onCompare(.init(start: source.start+sourceOffset, end: source.end+sourceOffset), take)
  }
}

struct DeliveryContour: View {
  let source: DeliveryTrack
  let take: DeliveryTrack
  let pitch: Bool
  var sourceElapsed: Double? = nil
  var takeElapsed: Double? = nil
  private var duration: Double { ReviewSignalScale.duration([source.duration, take.duration]) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EchoLocalizedText(pitch ? "review.signal.pitch_axis" : "review.signal.energy_axis")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        VStack {
          Text(verbatim: pitch ? "+12" : "0")
          Spacer()
          Text(verbatim: pitch ? "0" : "−20")
          Spacer()
          Text(verbatim: pitch ? "−12" : "−40")
        }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText).frame(width: 28)
        Canvas { context, size in
          for fraction in [0.0, 0.5, 1.0] {
            var line = Path(); line.move(to: .init(x: 0, y: size.height*fraction))
            line.addLine(to: .init(x: size.width, y: size.height*fraction))
            context.stroke(line, with: .color(EchoTheme.separator), lineWidth: 1)
          }
          for (track, color, dash, elapsed) in [
            (source, EchoTheme.accent, [CGFloat](), sourceElapsed),
            (take, EchoTheme.focus, [CGFloat(5), 4], takeElapsed)
          ] {
            var path = Path(), connected = false
            var previousTime: Double?
            for frame in track.frames {
              guard let x = ReviewSignalScale.fraction(time: frame.time, duration: duration),
                let value = pitch ? frame.pitchSemitones : Optional(frame.relativeDB), value.isFinite else {
                connected = false; previousTime = nil; continue
              }
              if let previousTime, frame.time - previousTime > 0.06 { connected = false }
              let normalized = pitch ? (value+12)/24 : (value+40)/40
              let point = CGPoint(x: x * size.width, y: (1-min(1,max(0,normalized)))*size.height)
              if connected { path.addLine(to: point) } else { path.move(to: point) }
              connected = true; previousTime = frame.time
            }
            context.stroke(path, with: .color(color), style: .init(lineWidth: 2, lineCap: .round, dash: dash))
            if let elapsed, let x = ReviewSignalScale.fraction(time: elapsed, duration: duration) {
              var cursor = Path(); cursor.move(to: .init(x: x * size.width, y: 0))
              cursor.addLine(to: .init(x: x * size.width, y: size.height))
              context.stroke(cursor, with: .color(color), style: .init(lineWidth: 1, dash: dash))
            }
          }
        }.accessibilityHidden(true)
      }.frame(height: 120)
      HStack {
        Text(verbatim: "0 s")
        Spacer()
        Text(verbatim: EchoFormat.decimal(duration / 2) + " s")
        Spacer()
        Text(verbatim: EchoFormat.decimal(duration) + " s")
      }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText).padding(.leading, 36)
      HStack(spacing: 16) {
        Label("Original sentence", systemImage: "line.diagonal").foregroundStyle(EchoTheme.accent)
        Label("Your full take", systemImage: "line.diagonal.arrow").foregroundStyle(EchoTheme.focus)
      }.font(EchoFont.metadata)
    }.padding(12).background(EchoTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
  }
}
