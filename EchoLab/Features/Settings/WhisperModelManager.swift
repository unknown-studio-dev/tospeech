import Foundation
import SwiftUI

/// One row in the Settings transcription-model list.
struct TranscriptionModelState: Identifiable, Equatable, Sendable {
  let variant: WhisperModelVariant
  let status: String
  let isActive: Bool
  var id: String { variant.rawValue }
}

/// Pure mapping from persisted engine rows + active preference to the display
/// list. Always returns all four variants in catalog order so the Settings UI
/// is stable regardless of what has been installed.
enum TranscriptionModelStates {
  static func make(
    releases: [EngineReleaseRecord], active: String?
  ) -> [TranscriptionModelState] {
    let statusByVersion = Dictionary(
      releases.map { ($0.version, $0.status) }, uniquingKeysWith: { _, latest in latest })
    return WhisperModelCatalog.all.map { variant in
      TranscriptionModelState(
        variant: variant,
        status: statusByVersion[variant.whisperKitModel] ?? "not_installed",
        isActive: WhisperModelSelection.active(from: releases, selected: active) == variant)
    }
  }
}

/// Observable bridge for the Settings transcription-model section: reads install
/// state from the production database and drives downloads through the
/// transcriber. Active-model selection is stored by the caller in
/// `Preferences.activeTranscriptionModel`.
@MainActor @Observable
final class WhisperModelManager {
  private let database: ProductionDatabase
  private let transcriber: WhisperCaptionTranscriber
  private(set) var error: String?
  private(set) var releases: [EngineReleaseRecord] = []
  private(set) var inProgress: Set<String> = []
  private(set) var progress: [String: Double] = [:]

  init(database: ProductionDatabase, transcriber: WhisperCaptionTranscriber) {
    self.database = database
    self.transcriber = transcriber
  }

  func states(active: String?) -> [TranscriptionModelState] {
    TranscriptionModelStates.make(releases: releases, active: active)
  }

  func isDownloading(_ variant: WhisperModelVariant) -> Bool {
    inProgress.contains(variant.whisperKitModel)
  }

  func refresh() async {
    do { releases = try await database.engineReleases(engineKey: WhisperModelCatalog.engineKey) }
    catch { self.error = error.localizedDescription }
  }

  func install(_ variant: WhisperModelVariant) async {
    let key = variant.whisperKitModel
    inProgress.insert(key)
    progress[key] = 0
    await refresh()
    error = nil
    do { try await transcriber.install(
      variant,
      onProgress: { fraction in
        Task { @MainActor in self.progress[key] = fraction }
      }) } catch { self.error = error.localizedDescription }
    inProgress.remove(key)
    await refresh()
  }

  func remove(_ variant: WhisperModelVariant) async {
    error = nil
    do { try await transcriber.remove(variant) }
    catch { self.error = error.localizedDescription }
    await refresh()
  }
}

extension EnvironmentValues {
  @Entry var whisperModelManager: WhisperModelManager?
}
