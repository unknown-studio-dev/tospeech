import SwiftUI
import OSLog

enum ModelInstallationError: LocalizedError, EchoCopyConvertible {
  case verificationFailed(String)

  var errorDescription: String? {
    switch self {
    case .verificationFailed(let name): "Could not verify the \(name) package after installation."
    }
  }

  var copy: EchoCopy {
    switch self {
    case .verificationFailed(let name): EchoCopy("onboarding.error.verify", arguments: [.raw(name)])
    }
  }
}

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
      Logger(subsystem: "com.unknownstudio.tospeech", category: "Parakeet").error("Installation check failed: \(error)")
      failure = "transcription.package.check_failed"
    }
  }

  func install() async {
    guard !isInstalling else { return }
    isInstalling = true
    failure = nil
    defer { isInstalling = false }
    do {
      try await installRequired()
    } catch {
      Logger(subsystem: "com.unknownstudio.tospeech", category: "Parakeet").error("Installation failed: \(error)")
      failure = "transcription.package.install_failed"
    }
  }

  /// Mandatory onboarding uses the same verified installer as Settings, but
  /// needs the failure to propagate so the app gate cannot be completed early.
  func installRequired() async throws {
    if try await adapter.installed() {
      isInstalled = true
      return
    }
    try await adapter.install(onProgress: { _ in })
    isInstalled = try await adapter.installed()
    guard isInstalled else { throw ModelInstallationError.verificationFailed("Parakeet") }
  }
}

extension EnvironmentValues {
  @Entry var parakeetModelManager: ParakeetModelManager?
}
