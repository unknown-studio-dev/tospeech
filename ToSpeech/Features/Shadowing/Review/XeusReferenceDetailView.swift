import SwiftUI

struct XeusReferenceDetailView: View {
  @Environment(\.locale) private var locale
  let detail: XeusPhoneDiagnostic
  let group: XeusReferenceDiagnostics.Group
  var policy: String? = nil
  var metricsExpanded: Binding<Bool>? = nil

  private func copy(_ key: String) -> String { EchoLocalization.string(key, locale: locale) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      EchoLocalizedText("assessment.reference.model_sequence").font(EchoFont.body(size: 14, weight: .semibold))
      sequence("assessment.reference.source", group.source)
      sequence("assessment.reference.take", group.take)
      EchoLocalizedText(group.hasMatchingSequence && detail.state == "INSUFFICIENT_EVIDENCE"
        ? "assessment.reference.sequence_matches" : "assessment.reference.state.\(detail.state)")
        .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
      if detail.state == "INSUFFICIENT_EVIDENCE", detail.takeHypothesis.reason == "ambiguous",
        ["xeus-uk-ctc-evidence-v3-diagnostics", "xeus-uk-ctc-evidence-v4-realizations",
          PhoneticXeusPackage.evidencePolicy].contains(policy ?? "") {
        if let support = detail.takeHypothesis.expectedProbability, support < 0.6 {
          Text(verbatim: EchoLocalization.format("assessment.reference.support_gate", locale: locale,
            arguments: [support, 0.6])).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
        if let margin = detail.takeHypothesis.logMargin, margin < log(4) {
          Text(verbatim: EchoLocalization.format("assessment.reference.margin_gate", locale: locale,
            arguments: [exp(max(-60, margin)), 4.0])).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
        }
      }
      if group.shared {
        Text(verbatim: EchoLocalization.format("assessment.reference.shared", locale: locale,
          arguments: [group.members.map(\.displayPhone).joined(separator: " ")]))
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }
      if group.takeBoundaryShared == true {
        EchoLocalizedText("assessment.reference.boundary_shared").font(EchoFont.metadata)
      }
      if detail.lengthStatus == "UNVERIFIED" {
        EchoLocalizedText("assessment.reference.length_unverified").font(EchoFont.metadata)
      }
      EchoDisclosureGroup("assessment.reference.measurements", isExpanded: metricsExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          EchoLocalizedText("assessment.reference.uncalibrated")
          if let distance = group.comparison.jsDistance {
            Text(verbatim: String(format: "JSD / DTW: %.5f", distance))
          } else { EchoLocalizedText("assessment.reference.no_distance") }
          metrics("assessment.reference.source", group.source, detail.sourceHypothesis)
          metrics("assessment.reference.take", group.take, detail.takeHypothesis)
          EchoLocalizedText("assessment.reference.time_hint")
        }.font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText).textSelection(.enabled)
      }
    }.fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func sequence(_ title: String, _ region: XeusReferenceDiagnostics.Region?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      EchoLocalizedText(title).font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      if let region, !region.tokens.isEmpty {
        Text(verbatim: "[\(region.sequence)]").font(EchoFont.body(size: 22)).textSelection(.enabled)
      } else { EchoLocalizedText("assessment.reference.no_tokens").font(EchoFont.body(size: 14)) }
    }
  }

  @ViewBuilder private func metrics(_ title: String, _ region: XeusReferenceDiagnostics.Region?,
    _ hypothesis: XeusPhoneDiagnostic.Hypothesis) -> some View {
    EchoLocalizedText(title).fontWeight(.semibold)
    if let region {
      Text(verbatim: String(format: "%.2f–%.2f s · frames %d..<%d", region.start, region.end, region.startFrame, region.endFrame))
      Text(verbatim: "\(copy("assessment.reference.emissions")): \(region.speechFrames) · blank \(String(format: "%.3f", region.blankMean))")
      ForEach(Array(region.tokens.enumerated()), id: \.offset) { _, token in
        Text(verbatim: "[\(token.symbol)] · \(token.startFrame)..<\(token.endFrame) · \(String(format: "%.3f", token.posterior))")
      }
      Text(verbatim: "\(copy("assessment.reference.competitors")): " + region.topCandidates.map {
        "\($0.symbol) \(String(format: "%.3f", $0.posterior))"
      }.joined(separator: " · "))
    }
    if let support = hypothesis.expectedProbability, let margin = hypothesis.logMargin {
      Text(verbatim: String(format: "%@ %.3f · %@ %.2f", copy("assessment.xeus.support"), support, copy("assessment.xeus.margin"), margin))
    }
  }
}
