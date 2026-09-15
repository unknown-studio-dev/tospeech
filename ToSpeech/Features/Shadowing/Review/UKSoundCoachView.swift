import SwiftUI

struct UKSoundCoachView: View {
  @Environment(\.locale) private var locale
  let symbol: String
  let onSpeak: (String) -> Void

  private let variants: Set<String> = ["ɐ", "ʔ", "l̩", "n̩", "m̩", "i", "u", "ɛː", "ɪː", "ʊː"]
  private var variantExamples: [String]? {
    switch symbol {
    case "l̩": ["bottle", "little"]
    case "n̩": ["button", "sudden"]
    case "m̩": ["rhythm", "prism"]
    case "i": ["happy", "city"]
    case "u": ["to", "influence"]
    case "ʔ": ["uh-oh"]
    default: nil
    }
  }

  var body: some View {
    if let guide = UKSoundLibrary.guide(for: symbol) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          EchoLocalizedText("coach.title").font(EchoFont.body(size: 15, weight: .semibold))
          Spacer()
          Text(verbatim: "/\(symbol)/ · UK").font(EchoFont.body(size: 20)).foregroundStyle(EchoTheme.accent)
        }
        if variants.contains(symbol) {
          EchoLocalizedText("coach.variant.\(symbol)").fixedSize(horizontal: false, vertical: true)
        } else {
          Text(verbatim: guide.mouth(locale: locale)).fixedSize(horizontal: false, vertical: true)
          Text(verbatim: guide.cue(locale: locale)).foregroundStyle(EchoTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        EchoLocalizedText("coach.examples").font(EchoFont.metadata)
        WordFlowLayout(spacing: 6, lineSpacing: 6) {
          ForEach(variantExamples ?? guide.examples, id: \.self) { word in
            EchoButton(word, symbol: "speaker.wave.2") { onSpeak(word) }
          }
          if variantExamples == nil {
            EchoButton(guide.contrast.joined(separator: " → "), symbol: "headphones", kind: .ghost) {
              onSpeak(guide.contrast.joined(separator: ". "))
            }.accessibilityLabel(EchoLocalization.string("coach.contrast", locale: locale))
          }
        }
        EchoLocalizedText("coach.synthetic").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(EchoFont.body(size: 14))
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

struct UKSoundLibraryView: View {
  @Environment(\.locale) private var locale
  @Binding var selectedSymbol: String
  let onSpeak: (String) -> Void
  let onSpeakSound: (String) -> Void
  var playingSymbol: String? = nil
  var showsDetail = true
  @State private var group: UKSoundGuide.Group = .vowels

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      EchoLocalizedText("coach.library").font(EchoFont.heading(size: 22))
      EchoLocalizedText("coach.chart_hint").font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      EchoSegmented(selection: $group, options: UKSoundGuide.Group.allCases.map { ($0, "coach.group.\($0.rawValue)") })
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
        ForEach(UKSoundLibrary.all.filter { $0.group == group }) { guide in
          EchoRowButton(selected: selectedSymbol == guide.symbol, minimumHeight: 36,
            action: {
              onSpeakSound(guide.symbol)
              selectedSymbol = guide.symbol
            }) {
            Text(verbatim: "/\(guide.symbol)/").font(EchoFont.body(size: 19))
              .frame(maxWidth: .infinity)
              .overlay(alignment: .topTrailing) {
                if playingSymbol == guide.symbol {
                  Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 8)).foregroundStyle(EchoTheme.accent)
                }
              }
          }
          .accessibilityLabel(EchoLocalization.format("coach.play_sound", locale: locale,
            arguments: [guide.symbol]))
          .accessibilityValue(playingSymbol == guide.symbol
            ? EchoLocalization.string("coach.playing", locale: locale) : "")
          .help(guide.examples.joined(separator: ", "))
        }
      }
      if showsDetail { UKSoundCoachView(symbol: selectedSymbol, onSpeak: onSpeak) }
    }
    .onAppear { group = UKSoundLibrary.guide(for: selectedSymbol)?.group ?? .vowels }
    .onChange(of: group) {
      if UKSoundLibrary.guide(for: selectedSymbol)?.group != group {
        selectedSymbol = UKSoundLibrary.all.first { $0.group == group }!.symbol
      }
    }
  }
}
