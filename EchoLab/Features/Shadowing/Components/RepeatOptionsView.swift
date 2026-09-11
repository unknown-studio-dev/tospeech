import SwiftUI

struct RepeatOptionsView: View {
  let onClose: () -> Void
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  @State private var draft = Preferences()
  @State private var advanced = false

  init(onClose: @escaping () -> Void, initiallyExpanded: Bool = false) {
    self.onClose = onClose
    _advanced = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    EchoDialog(
      title: "Repeat & record", subtitle: "", width: 420, height: advanced ? 480 : 380,
      titleSize: 18, close: onClose
    ) {
      VStack(alignment: .leading, spacing: 10) {
        compactChoiceRow(
          title: "Repeat count", values: PracticeOptions.repeatCounts, selection: $draft.repeats
        ) { "\($0)×" }
        compactChoiceRow(
          title: "Countdown", values: PracticeOptions.countdowns, selection: $draft.countdown
        ) { secondsLabel($0) }

        Toggle(isOn: $draft.autoRecord) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Record after every listen").font(EchoFont.body(size: 13, weight: .medium))
            Text("Listen finishes before countdown and capture.").font(EchoFont.metadata)
              .foregroundStyle(EchoTheme.muted)
          }
        }.toggleStyle(EchoToggleStyle()).padding(10).background(
          EchoTheme.selected, in: RoundedRectangle(cornerRadius: 10))
        DisclosureGroup("Advanced options", isExpanded: $advanced) {
          VStack(alignment: .leading, spacing: 8) {
            compactChoiceRow(
              title: "Playback speed", values: PracticeOptions.speeds, selection: $draft.speed
            ) { "\(EchoFormat.decimal($0))×" }
            compactChoiceRow(
              title: "Stop after silence", values: [1.2, 2, 3], selection: $draft.silence
            ) { secondsLabel($0) }
          }.padding(.top, 5)
        }.font(EchoFont.body(size: 12, weight: .medium))
      }
    } footer: {
      HStack {
        Text("Independent take per round.").font(EchoFont.metadata).foregroundStyle(EchoTheme.muted)
        Spacer()
        EchoButton("Cancel", surface: EchoTheme.surface, action: onClose)
        EchoButton("Apply", symbol: "checkmark", kind: .primary) {
          store.preferences = draft
          onClose()
        }
      }
    }.onAppear { draft = store.preferences }
  }

  private func compactChoiceRow<Value: Hashable>(
    title: String, values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String
  ) -> some View {
    // Measure the complete labels, not compressed text that appears to fit by wrapping.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        EchoLocalizedText(title).font(EchoFont.body(size: 13, weight: .medium))
          .fixedSize()
        Spacer(minLength: 0)
        choices(values: values, selection: selection, label: label)
      }
      VStack(alignment: .leading, spacing: 8) {
        EchoLocalizedText(title).font(EchoFont.body(size: 13, weight: .medium))
        choices(values: values, selection: selection, label: label)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func choices<Value: Hashable>(
    values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String
  ) -> some View {
    HStack(spacing: 5) {
      ForEach(values, id: \.self) { value in
        EchoButton(
          label(value), kind: selection.wrappedValue == value ? .primary : .secondary,
          surface: EchoTheme.surface
        ) {
          selection.wrappedValue = value
        }
        .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
      }
    }.fixedSize(horizontal: true, vertical: false)
  }

  private func secondsLabel(_ value: Double) -> String {
    EchoLocalization.format(
      "duration.seconds", locale: locale, arguments: [EchoFormat.decimal(value)])
  }
}
