import SwiftUI

struct ProductionAssessmentModelsView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  let manager: PronunciationModelManager
  @State private var confirmingRemoval = false
  @State private var removingEngine: EngineID = .buddy
  private func copy(_ key: String) -> String { EchoLocalization.string(key, locale: locale) }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Model đánh giá").font(EchoFont.heading(size: 20, weight: .semibold))
        Spacer()
        EchoButton("assessment.disable", kind: .ghost) { store.preferences.productionAssessmentEngine = nil }
          .disabled(store.preferences.productionAssessmentEngine == nil || manager.isBusy())
      }
      EchoLocalizedText("assessment.models_intro").font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.secondaryText)
      ModelCardView(title: "UK Reference · UK", statusLine: copy(manager.ukInstalled ? "assessment.uk.installed" : "assessment.uk.size"),
        isActive: store.preferences.productionAssessmentEngine == .ukReference, activeLabel: copy("assessment.active"),
        errorText: manager.ukFailure.map(copy)) {
        if manager.ukInstalling {
          EchoLoading(title: "assessment.installing")
        } else if !manager.ukInstalled {
          EchoButton("assessment.install") { manager.installUK() }
        } else {
          EchoButton("assessment.activate", kind: .primary) { store.preferences.productionAssessmentEngine = .ukReference }
            .disabled(store.preferences.productionAssessmentEngine == .ukReference || manager.isBusy() || store.preferences.accent != .uk)
          EchoButton("assessment.remove", kind: .ghost) { removingEngine = .ukReference; confirmingRemoval = true }
            .disabled(manager.isBusy() || store.preferences.productionAssessmentEngine == .ukReference || manager.xeusInstalled)
        }
      } footer: {
        EchoLocalizedText("assessment.uk.details").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
        if store.preferences.accent != .uk { EchoLocalizedText("assessment.uk.error.accent").font(EchoFont.metadata) }
      }
      // Release builds ship without the PhoneticXeus runtime; offering a download that cannot work would mislead.
      if manager.xeusAvailable {
        ModelCardView(title: "PhoneticXeus · UK Experimental",
          statusLine: copy(manager.xeusReady ? "assessment.xeus.installed" : "assessment.xeus.size"),
          isActive: store.preferences.productionAssessmentEngine == .phoneticXeus,
          activeLabel: copy("assessment.active"), errorText: manager.xeusFailure.map(copy)) {
          if manager.xeusInstalling {
            EchoLoading(title: "assessment.installing")
            EchoButton("Cancel", kind: .ghost) { manager.cancelXeus() }
          } else if !manager.xeusReady {
            EchoButton("assessment.install") { manager.installXeus() }
          } else {
            EchoButton("assessment.activate", kind: .primary) { store.preferences.productionAssessmentEngine = .phoneticXeus }
              .disabled(store.preferences.productionAssessmentEngine == .phoneticXeus || manager.isBusy() || store.preferences.accent != .uk)
            EchoButton("assessment.remove", kind: .ghost) { removingEngine = .phoneticXeus; confirmingRemoval = true }
              .disabled(manager.isBusy() || store.preferences.productionAssessmentEngine == .phoneticXeus)
          }
        } footer: {
          EchoLocalizedText("assessment.xeus.details").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
          if store.preferences.accent != .uk { EchoLocalizedText("assessment.uk.error.accent").font(EchoFont.metadata) }
        }
      }
      ModelCardView(title: "Buddy · English v1", statusLine: copy(manager.isInstalled ? "assessment.installed" : "assessment.download_size"),
        isActive: store.preferences.productionAssessmentEngine == .buddy, activeLabel: copy("assessment.active"),
        errorText: manager.failure.map(copy)) {
        if manager.isInstalling {
          EchoButton("Cancel", kind: .ghost) { manager.cancel() }
        } else if !manager.isInstalled {
          EchoButton("assessment.install") { manager.install() }
        } else {
          EchoButton("assessment.activate", kind: .primary) { store.preferences.productionAssessmentEngine = .buddy }
            .disabled(store.preferences.productionAssessmentEngine == .buddy || manager.isBusy())
          EchoButton("assessment.remove", kind: .ghost) { removingEngine = .buddy; confirmingRemoval = true }.disabled(manager.isBusy() || store.preferences.productionAssessmentEngine == .buddy)
        }
      } footer: {
        if manager.isInstalling { EchoLoading(title: "assessment.installing") }
        EchoLocalizedText("assessment.buddy_details").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.muted)
      }
      ModelCardView(title: "Phone Scorer · E16 · US", statusLine: copy(manager.phoneInstalled ? "assessment.phone_scorer.installed" : "assessment.phone_scorer.size"),
        isActive: store.preferences.productionAssessmentEngine == .phone, activeLabel: copy("assessment.active"),
        errorText: manager.phoneFailure.map(copy)) {
        if manager.phoneInstalling {
          EchoLoading(title: "assessment.installing")
        } else if !manager.phoneInstalled {
          EchoButton("assessment.phone_scorer.install") { manager.installPhone() }
        } else {
          EchoButton("assessment.activate", kind: .primary) { store.preferences.productionAssessmentEngine = .phone }
            .disabled(store.preferences.productionAssessmentEngine == .phone || manager.isBusy())
          EchoButton("assessment.remove", kind: .ghost) { removingEngine = .phone; confirmingRemoval = true }
            .disabled(manager.isBusy() || store.preferences.productionAssessmentEngine == .phone)
        }
      } footer: {
        EchoLocalizedText("assessment.phone_scorer.details").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.secondaryText)
        if store.preferences.accent == .uk {
          EchoLocalizedText("assessment.phone_scorer.accent").font(EchoFont.body(size: 12)).foregroundStyle(EchoTheme.caution)
        }
      }
    }
    .task { await manager.refresh() }
    .confirmationDialog("Xóa gói model?", isPresented: $confirmingRemoval) {
      Button(role: .destructive) { // native-control: confirmation
        Task {
          if removingEngine == .phoneticXeus { await manager.removeXeus() }
          else if removingEngine == .ukReference { await manager.removeUK() }
          else if removingEngine == .phone { await manager.removePhone() } else { await manager.remove() }
          let removed = removingEngine == .phoneticXeus ? !manager.xeusInstalled : removingEngine == .ukReference ? !manager.ukInstalled : removingEngine == .phone ? !manager.phoneInstalled : !manager.isInstalled
          if removed && store.preferences.productionAssessmentEngine == removingEngine { store.preferences.productionAssessmentEngine = nil }
        }
      } label: { Text("assessment.remove") }
      Button("Giữ lại", role: .cancel) {} // native-control: confirmation
    } message: { Text("Bản thu và các kết quả đánh giá trước đây vẫn được giữ lại.") }
  }
}
