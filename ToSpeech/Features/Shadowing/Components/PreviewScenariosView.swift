import SwiftUI

struct PreviewScenariosView: View {
  @Environment(EchoStore.self) private var store
  var body: some View {
    @Bindable var practice = store.practice
    @Bindable var store = store
    EchoPanel(padding: 16) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Interaction testing only. These controls do not access real audio or models.").font(
          EchoFont.body(size: 11))
        HStack(spacing: 16) {
          EchoSelect(
            label: "Capture outcome",
            selection: Binding(
              get: { practice.simulatedOutcome.rawValue },
              set: { practice.simulatedOutcome = CaptureOutcome(rawValue: $0) ?? .complete }),
            options: CaptureOutcome.allCases.map { ($0.rawValue, $0.label) }
          ).frame(width: 260)
          EchoCheckbox(title: "Fail save", isOn: $practice.simulateSaveFailure)
          EchoCheckbox(title: "Fail next assessment", isOn: $store.failNextAssessment)
        }
        HStack {
          EchoButton("Finish source now") { practice.sourceFinished() }.disabled(
            practice.phase != .listening)
          EchoButton("Simulate speech") { practice.speechDetected() }.disabled(
            !practice.phase.isCapture)
          EchoButton("Reset mic permission") {
            if practice.interrupt() { practice.permission = "unknown" }
          }
        }
      }
    }
  }
}
