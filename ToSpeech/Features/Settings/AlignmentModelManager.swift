import SwiftUI
import OSLog

/// Word alignment is used by every practice session regardless of reference accent (mirrors
/// `ParakeetModelManager`, which is also installed unconditionally at onboarding).
@MainActor @Observable
final class AlignmentModelManager {
  private let package: AlignmentPackage
  private(set) var isInstalled = false
  private(set) var isInstalling = false
  private(set) var failure: String?

  init(package: AlignmentPackage) { self.package = package }

  func refresh() async {
    isInstalled = await package.installed()
  }

  func install() async {
    guard !isInstalling else { return }
    isInstalling = true
    failure = nil
    defer { isInstalling = false }
    do {
      try await installRequired()
    } catch {
      Logger(subsystem: "com.unknownstudio.tospeech", category: "Alignment").error("Installation failed: \(error)")
      failure = "transcription.alignment.install_failed"
    }
  }

  /// Mandatory onboarding uses the same verified installer as Settings, but
  /// needs the failure to propagate so the app gate cannot be completed early.
  func installRequired() async throws {
    if await package.installed() {
      isInstalled = true
      return
    }
    try await package.install()
    isInstalled = await package.installed()
    guard isInstalled else { throw ModelInstallationError.verificationFailed("Word Alignment") }
  }
}

extension EnvironmentValues {
  @Entry var alignmentModelManager: AlignmentModelManager?
}
