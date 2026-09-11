import SwiftUI
import OSLog

@MainActor @Observable
final class ParakeetModelManager {
  private let adapter: ParakeetTranscriptionAdapter
  private(set) var isInstalled = false
  private(set) var isInstalling = false
  private(set) var failure: String?

  init(adapter: ParakeetTranscriptionAdapter) { self.adapter = adapter }

  func refresh() async {
    do { isInstalled = try await adapter.installed() }
    catch {
      Logger(subsystem: "studio.unknown.EchoLab", category: "Parakeet").error("Installation check failed: \(error)")
      failure = "transcription.package.check_failed"
    }
  }

  func install() async {
    guard !isInstalling else { return }
    isInstalling = true
    failure = nil
    defer { isInstalling = false }
    do {
      try await adapter.install(onProgress: { _ in })
      await refresh()
    } catch {
      Logger(subsystem: "studio.unknown.EchoLab", category: "Parakeet").error("Installation failed: \(error)")
      failure = "transcription.package.install_failed"
    }
  }
}

extension EnvironmentValues {
  @Entry var parakeetModelManager: ParakeetModelManager?
}
