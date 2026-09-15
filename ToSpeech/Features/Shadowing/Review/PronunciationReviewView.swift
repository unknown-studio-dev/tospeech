import SwiftUI

struct PronunciationReviewView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  let history: [PronunciationJob]
  var error: String? = nil
  let onRetry: (PronunciationJob) -> Void
  let onRecover: () -> Void
  let onAssess: () -> Void
  let onReplay: (Double, Double) -> Void
  var onSourceReplay: (Double, Double) -> Void = { _, _ in }
  @State private var selectedID = ""
  private var job: PronunciationJob? { history.first { $0.id.uuidString == selectedID } ?? history.last }
  private func copy(_ key: String) -> String { EchoLocalization.string(key, locale: locale) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Eyebrow("assessment.title")
      if let error {
        EchoNotice(text: copy(error), error: true)
        EchoButton("Retry assessment") { onRecover() }
      }
      if let job {
        if history.count > 1 {
          EchoSelect(label: "Assessment history", selection: Binding(get: { self.job?.id.uuidString ?? "" }, set: { selectedID = $0 }),
            options: history.map { ($0.id.uuidString, "\($0.engineTitle) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(copy("assessment.status.\($0.status.rawValue)"))") })
        }
        if job.isPending { EchoLoading(title: "assessment.status.\(job.status.rawValue)") }
        if let error = job.error {
          EchoNotice(text: copy(error), error: job.status == .failed)
          EchoButton("Retry assessment") { onRetry(job) }
          if error == "assessment.error.model_missing" {
            EchoButton("Choose a model", kind: .ghost) { store.navigate(.settings) }
          }
        }
        if let result = job.result { evidence(result) }
        EchoDisclosureGroup("Engine details") {
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: job.provenance).textSelection(.enabled)
            Text(verbatim: "\(job.accent.rawValue) · \(job.target.segmentRevisionID.uuidString)")
            Text(verbatim: "SHA256 \(job.audioChecksum)").textSelection(.enabled)
            EchoLocalizedText(job.provenance.hasPrefix("PhoneticXeus") ? "assessment.xeus.details" : job.provenance.hasPrefix("UK Reference") ? "assessment.uk.details" : "assessment.limitations")
          }.font(EchoFont.body(size: 10)).foregroundStyle(EchoTheme.muted)
        }
      } else {
        EchoLocalizedText(store.preferences.productionAssessmentEngine.map { [.buddy, .phone, .ukReference, .phoneticXeus].contains($0) } == true
          ? "assessment.empty_active" : "assessment.empty").font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.muted)
      }
      if store.preferences.productionAssessmentEngine.map { [.buddy, .phone, .ukReference, .phoneticXeus].contains($0) } == true {
        EchoButton(history.isEmpty ? "assessment.start" : "assessment.rerun",
          kind: history.isEmpty ? .primary : .ghost, action: onAssess).disabled(history.contains(where: \.isPending))
      } else {
        EchoButton("Choose a model", kind: .ghost) { store.navigate(.settings) }
      }
    }
  }

  private func evidence(_ result: PronunciationEvidence) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: EchoLocalization.format("assessment.summary", locale: locale,
        arguments: [result.assessedWords, result.words.count, result.changedWords]))
        .font(EchoFont.body(size: 14, weight: .semibold))
      EchoLocalizedText("assessment.candidate_notice").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
      Text(verbatim: EchoLocalization.format("assessment.duration", locale: locale, arguments: [EchoFormat.decimal(result.duration)]))
        .font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      ForEach(Array(result.words.filter { $0.supported && !$0.differences.isEmpty }.prefix(2))) { word in
        wordDetail(word, duration: result.duration)
      }
      EchoDisclosureGroup("assessment.all_words") {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(result.words) { word in wordDetail(word, duration: result.duration) }
        }.padding(.top, 8)
      }
      if result.words.contains(where: { !$0.supported }) {
        EchoNotice(text: copy("assessment.unsupported_words"))
        Text(verbatim: result.recognizedPhones.map(\.symbol).joined(separator: " "))
          .font(EchoFont.body(size: 13)).textSelection(.enabled)
      }
    }
  }

  private func wordDetail(_ word: WordPronunciationEvidence, duration: Double) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(verbatim: word.target.text).font(EchoFont.body(size: 14, weight: .semibold))
        Text(verbatim: word.referenceIPA.map { "/\($0)/" } ?? "—").font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
        Spacer(minLength: 0)
        if let start = word.target.sourceStart, let end = word.target.sourceEnd, end > start {
          EchoIconButton(symbol: "speaker.wave.2", label: "assessment.hear_source") { onSourceReplay(start, end) }
        }
      }
      if !word.supported { EchoLocalizedText("assessment.word_unsupported") }
      else if !word.phones.isEmpty && word.phones.allSatisfy({ $0.kind == .referenceUncertain }) {
        EchoLocalizedText("assessment.phone.referenceUncertain").foregroundStyle(EchoTheme.muted)
      } else if word.observations.isEmpty {
        Label(copy("assessment.word_matches"), systemImage: "checkmark.circle").foregroundStyle(EchoTheme.success)
      } else {
        ForEach(word.observations) { phone in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
              Text(verbatim: "\(phone.expected.map { "/\($0)/" } ?? "∅") → \(phone.observed.map { "/\($0)/" } ?? "∅") · \(copy("assessment.phone.\(phone.kind.rawValue)"))")
              if let expected = phone.expected, ["θ", "ð", "v", "ɹ", "ʃ", "ŋ"].contains(expected) {
                EchoLocalizedText("assessment.tip.\(expected)").foregroundStyle(EchoTheme.muted)
              }
            }
            Spacer(minLength: 0)
            if let start = phone.start, let end = phone.end {
              EchoIconButton(symbol: "play.fill", label: "assessment.hear_region") {
                onReplay(max(0, start-0.18), min(duration, end+0.18))
              }
            }
          }
        }
      }
    }
    .font(EchoFont.body(size: 12))
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(EchoTheme.raised, in: RoundedRectangle(cornerRadius: 10))
  }
}
