import SwiftUI

/// Shared transport composition. Callers provide actions and mode-specific
/// options/status; this component has no recorder, lesson or dictation state.
struct EchoPlaybackControls<Options: View, Status: View, Actions: View>: View {
  var compact = false
  var scale: CGFloat = 1
  var playSymbol: String
  var playTitle: String
  var playEnabled = true
  var previousEnabled: Bool
  var nextEnabled: Bool
  var playShortcut: KeyboardShortcut? = nil
  var playIdentifier = "play-loop"
  var onPrevious: () -> Void
  var onPlay: () -> Void
  var onNext: () -> Void
  var speedTitle: String
  var speedSubtitle: String
  var speedEnabled = true
  var speedOptionsPresented: Binding<Bool>
  var onSpeedOptions: () -> Void
  @ViewBuilder var options: Options
  @ViewBuilder var status: Status
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(spacing: compact ? 12 : 24) {
      HStack(spacing: compact ? 8 : 12) {
        EchoTransportButton(symbol: "backward.end", title: "Previous sentence",
          width: compact ? 32 : 40, height: 44, circular: true, action: onPrevious)
          .disabled(!previousEnabled)
        EchoTransportButton(symbol: playSymbol, title: playTitle,
          width: 54 * scale, height: 54 * scale, primary: true, circular: true, action: onPlay)
          .disabled(!playEnabled).keyboardShortcut(playShortcut)
          .accessibilityIdentifier(playIdentifier)
        EchoTransportButton(symbol: "forward.end", title: "Next sentence",
          width: compact ? 32 : 40, height: 44, circular: true, action: onNext)
          .disabled(!nextEnabled)
      }
      EchoTransportOptionsButton(title: speedTitle, subtitle: speedSubtitle,
        scale: scale, width: compact ? 84 : 116 * scale, action: onSpeedOptions)
        .disabled(!speedEnabled).echoHelp("Playback and repeat options")
        .popover(isPresented: speedOptionsPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
          options
        }
      Rectangle().fill(EchoTheme.border).frame(width: 1, height: 44)
      status
      Spacer(minLength: 0)
      actions
    }
  }
}

/// Same surface and timeline placement for listening, writing and capture states.
struct EchoTransportBar<Content: View, Timeline: View>: View {
  var minimumHeight: CGFloat = 108
  @ViewBuilder var content: Content
  @ViewBuilder var timeline: Timeline
  var body: some View {
    VStack(alignment: .leading, spacing: 18) { content }
      .padding(.horizontal, 24).padding(.vertical, 20)
      .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
      .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: EchoMetrics.panelRadius))
      .foregroundStyle(EchoTheme.text)
      .overlay(alignment: .top) { timeline.padding(.horizontal, 24) }
  }
}
