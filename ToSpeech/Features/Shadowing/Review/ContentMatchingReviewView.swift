import SwiftUI

struct ContentMatchingReviewView: View {
  let history: [ContentMatchingJob]
  var error: String?
  var onRetry: (ContentMatchingJob) -> Void
  var onRecover: () -> Void
  @State private var selectedJobID: String?
  @Environment(EchoStore.self) private var store

  private var selected: ContentMatchingJob? {
    history.first { $0.id.uuidString == selectedJobID } ?? history.last
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Eyebrow("matching.title")
      if let error {
        EchoNotice(copy: EchoCopy("matching.failure", arguments: [.raw(error)]), error: true)
        EchoButton("Retry", action: onRecover)
      }
      if let job = selected {
        if history.count > 1 {
          EchoSelect(label: "matching.history", selection: Binding(
            get: { selectedJobID ?? history.last!.id.uuidString }, set: { selectedJobID = $0 }),
            options: history.map { ($0.id.uuidString, "\($0.createdAt.formatted(date: .omitted, time: .shortened)) · \($0.selection.modelID)") })
        }
        switch job.status {
        case .queued: EchoLoading(title: "matching.queued")
        case .running: EchoLoading(title: "matching.running")
        case .failed:
          if let key = job.errorLocalizationKey {
            EchoNotice(text: key, error: true)
          } else {
            EchoNotice(copy: EchoCopy("matching.failure", arguments: [.raw(job.error ?? "")]), error: true)
          }
          if job.errorLocalizationKey == "matching.model_missing" {
            EchoButton("Choose a model") { store.navigate(.settings) }
          }
          EchoButton("matching.retry") { onRetry(job) }
        case .unrecognized:
          EchoNotice(text: "matching.unrecognized", error: true)
        case .complete:
          if let match = job.match {
            EchoNotice(text: match.differences.isEmpty ? "matching.full_match" : "matching.check_differences")
            EchoLocalizedText("matching.recognized").font(EchoFont.body(size: 12, weight: .semibold))
            Text(verbatim: job.transcription?.words.map(\.text).joined(separator: " ") ?? "")
              .font(EchoFont.body(size: 14)).textSelection(.enabled)
            if !match.differences.isEmpty {
              EchoLocalizedText("matching.priorities").font(EchoFont.body(size: 12, weight: .semibold))
              ForEach(Array(match.differences.prefix(2).enumerated()), id: \.offset) { _, word in
                wordRow(word)
              }
            }
            EchoDisclosureGroup("matching.word_detail") {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(match.words.enumerated()), id: \.offset) { _, word in wordRow(word) }
              }.padding(.top, 8)
            }
          }
        }
        EchoDisclosureGroup("Engine details") {
          VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(job.provenance.engine) · \(job.provenance.model)\n\(job.provenance.runtimeVersion) · \(job.locale) · \(job.policy)")
            EchoLocalizedText(EchoCopy("matching.target", arguments: [.raw(String(job.target.segmentRevisionID.uuidString.prefix(8)))]))
            Text(verbatim: job.target.text)
          }.font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
            .textSelection(.enabled).padding(.top, 8)
        }

      } else {
        EchoNotice(text: "matching.not_started")
      }
      EchoLocalizedText("matching.limitations")
        .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
    }
  }

  private func wordRow(_ word: ContentMatch.Word) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Label {
        EchoLocalizedText("matching.word.\(word.kind.rawValue)")
      } icon: {
        Image(systemName: word.kind == .matched ? "checkmark.circle" : "questionmark.circle")
      }
      .foregroundStyle(word.kind == .matched ? EchoTheme.success : EchoTheme.muted)
      Text(verbatim: [word.expected, word.observed].compactMap { $0 }.joined(separator: " → "))
        .textSelection(.enabled)
    }.font(EchoFont.body(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
  }
}
