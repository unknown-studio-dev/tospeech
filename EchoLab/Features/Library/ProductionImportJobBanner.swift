import SwiftUI

struct ProductionImportJobBanner: View {
  let job: ProductionImportJob
  let showStatus: () -> Void
  let cancel: () -> Void
  let retry: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) { content }
      VStack(alignment: .leading, spacing: 12) { content }
    }
    .padding(16)
    .background(
      job.phase == .failed ? EchoTheme.warning : EchoTheme.soft,
      in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder private var content: some View {
    Image(systemName: symbol)
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(EchoFont.body(size: 13, weight: .semibold))
      Text(detail).font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
    }
    Spacer()
    if !job.phase.isTerminal {
      EchoButton("import.presentation.banner.show_progress", kind: .secondary, action: showStatus)
      EchoButton("Cancel", kind: .ghost, action: cancel)
    } else if job.phase == .failed || job.phase == .cancelled {
      EchoButton("Retry", kind: .secondary, action: retry)
    }
  }

  private var symbol: String {
    switch job.phase {
    case .failed: "exclamationmark.triangle"
    case .cancelled: "xmark.circle"
    case .ready: "checkmark.circle"
    default: "arrow.down.circle"
    }
  }

  private var title: String {
    switch job.phase {
    case .resolving: "Reading video details"
    case .downloadingAudio: "Preparing source audio"
    case .probing: "Checking source audio"
    case .fetchingCaptions: "Finding English captions"
    case .preparingTranscript: "Checking transcript and word timing"
    case .publishing: "Saving lesson"
    case .ready: "Audio ready"
    case .failed: "Import needs attention"
    case .cancelled: "Import cancelled"
    }
  }

  private var detail: String {
    if let error = job.error { return error.presentationDescription }
    return "\(job.title) · continues in the background"
  }
}
