import SwiftUI

/// Shared presentational card for a downloadable model row (evaluation engines
/// and transcription models both use it, so they look identical). Purely
/// presentational: the caller supplies already-resolved copy and the trailing
/// action controls; the card owns the active highlight, status line, progress
/// and error chrome.
struct ModelCardView<Actions: View, Footer: View>: View {
  let title: String
  let statusLine: String
  let isActive: Bool
  var activeLabel: String
  var progressFraction: Double? = nil
  var progressTitle: String = ""
  var errorText: String? = nil
  @ViewBuilder var actions: () -> Actions
  @ViewBuilder var footer: () -> Footer

  init(
    title: String, statusLine: String, isActive: Bool, activeLabel: String,
    progressFraction: Double? = nil, progressTitle: String = "", errorText: String? = nil,
    @ViewBuilder actions: @escaping () -> Actions,
    @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
  ) {
    self.title = title
    self.statusLine = statusLine
    self.isActive = isActive
    self.activeLabel = activeLabel
    self.progressFraction = progressFraction
    self.progressTitle = progressTitle
    self.errorText = errorText
    self.actions = actions
    self.footer = footer
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Text(verbatim: title).font(EchoFont.body(size: 16, weight: .semibold))
        Spacer()
        if isActive {
          Label(activeLabel, systemImage: "checkmark.circle")
            .font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.success).fixedSize()
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          statusView
          Spacer(minLength: 0)
          HStack(spacing: 12) { actions() }.fixedSize()
        }
        VStack(alignment: .leading, spacing: 12) {
          statusView
          HStack { Spacer(); HStack(spacing: 12) { actions() }.fixedSize() }
        }
      }
      if let progressFraction {
        EchoLoading(title: progressTitle, fraction: progressFraction)
      }
      if let errorText { EchoNotice(text: errorText, error: true) }
      footer()
    }
    .padding(.horizontal, 20).padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(EchoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12).strokeBorder(isActive ? EchoTheme.success : .clear))
  }

  private var statusView: some View {
    Text(verbatim: statusLine).font(EchoFont.body(size: 14))
      .foregroundStyle(EchoTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
  }
}
