import SwiftUI

struct ImportJobBanner: View {
  let job: PreviewImportJob
  let store: EchoStore
  @Environment(\.locale) private var locale

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) { bannerContent }
      VStack(alignment: .leading, spacing: 12) { bannerContent }
    }
    .padding(16).background(
      job.phase == .failed ? EchoTheme.warning : EchoTheme.soft,
      in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder private var bannerContent: some View {
    Image(
      systemName: job.phase == .failed
        ? "exclamationmark.triangle"
        : job.phase == .ready ? "checkmark.circle" : "arrow.down.circle")
    VStack(alignment: .leading, spacing: 3) {
      EchoLocalizedText(bannerTitle)
      .font(EchoFont.body(size: 13, weight: .semibold))
      EchoLocalizedText(bannerDetail)
      .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
    }
    Spacer()
    if job.phase == .preparing { EchoButton("Cancel", kind: .ghost) { store.cancelImport() } }
    if job.phase == .failed { EchoButton("Retry", kind: .secondary) { store.retryImport() } }
    if job.phase == .ready, let id = job.lessonID {
      EchoButton("Start", symbol: "play.fill", kind: .primary) { store.openLesson(id) }
    }
  }

  private var bannerTitle: String {
    switch job.phase {
    case .preparing:
      EchoLocalization.format("import.preparing", locale: locale, arguments: [job.title])
    case .ready:
      EchoLocalization.format("import.ready", locale: locale, arguments: [job.title])
    case .failed, .cancelled:
      EchoLocalization.string("Import needs attention", locale: locale)
    }
  }

  private var bannerDetail: String {
    if job.phase == .preparing {
      return EchoLocalization.format(
        "import.step", locale: locale,
        arguments: [min(job.step + 1, PreviewImportJob.steps.count), PreviewImportJob.steps.count])
    }
    return job.error ?? EchoLocalization.string("Open to start practicing", locale: locale)
  }
}
