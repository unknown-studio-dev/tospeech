import SwiftUI

@MainActor @Observable
final class PronunciationModelManager {
  let package: BuddyModelPackage
  let phonePackage: PhoneScorerPackage?
  let ukPackage: UKReferencePackage?
  let xeusPackage: PhoneticXeusPackage?
  /// False only when a build carries no PhoneticXeus runtime: the card is not shown.
  private(set) var xeusAvailable = false
  private(set) var xeusInstalled = false
  private(set) var xeusInstalling = false
  private(set) var xeusFailure: String?
  private var xeusInstallation: Task<Void, Never>?
  private(set) var ukInstalled = false
  private(set) var ukInstalling = false
  private(set) var ukFailure: String?
  private(set) var phoneInstalled = false
  private(set) var phoneInstalling = false
  private(set) var phoneFailure: String?
  private(set) var isInstalled = false
  private(set) var isInstalling = false
  private(set) var failure: String?
  private var installation: Task<Void, Never>?
  var isBusy: @MainActor () -> Bool = { false }
  init(package: BuddyModelPackage, phonePackage: PhoneScorerPackage? = nil, ukPackage: UKReferencePackage? = nil, xeusPackage: PhoneticXeusPackage? = nil) {
    self.package = package; self.phonePackage = phonePackage; self.ukPackage = ukPackage; self.xeusPackage = xeusPackage
  }
  func refresh() async {
    xeusAvailable = await xeusPackage?.runtimeAvailable() ?? false
    xeusInstalled = await xeusPackage?.installed() ?? false
    ukInstalled = await ukPackage?.installed() ?? false
    isInstalled = await package.installed()
    phoneInstalled = await phonePackage?.installed() ?? false
  }
  /// PhoneticXeus and UK Reference are one UK engine (XEUS grades phones, UK Reference measures
  /// delivery): install UK Reference first when missing, then XEUS; remove both together.
  var xeusReady: Bool { xeusInstalled && ukInstalled }
  func installXeus() {
    guard let xeusPackage, !xeusInstalling else { return }
    xeusInstalling = true; xeusFailure = nil
    xeusInstallation = Task {
      defer { xeusInstalling = false; xeusInstallation = nil }
      do {
        if let ukPackage, !(await ukPackage.installed()) { try await ukPackage.install() }
        try await xeusPackage.install()
        await refresh()
      }
      catch is CancellationError { await refresh() }
      catch let error as URLError where error.code == .cancelled { await refresh() }
      catch { xeusFailure = error.localizedDescription; await refresh() }
    }
  }
  func cancelXeus() { xeusInstallation?.cancel() }
  func removeXeus() async {
    guard !isBusy(), !xeusInstalling else { xeusFailure = "assessment.error.busy"; return }
    do {
      try await xeusPackage?.remove()
      try await ukPackage?.remove()
      await refresh()
    }
    catch { xeusFailure = error.localizedDescription; await refresh() }
  }
  func installPhone() {
    guard let phonePackage, !phoneInstalling else { return }
    phoneInstalling = true; phoneFailure = nil
    Task {
      defer { phoneInstalling = false }
      do { try await phonePackage.install(); await refresh() }
      catch { phoneFailure = error.localizedDescription; await refresh() }
    }
  }
  func removePhone() async {
    guard !isBusy(), !phoneInstalling else { phoneFailure = "assessment.error.busy"; return }
    do { try await phonePackage?.remove(); await refresh() }
    catch { phoneFailure = error.localizedDescription }
  }
  func install() {
    guard !isInstalling else { return }
    isInstalling = true; failure = nil
    installation = Task {
      defer { isInstalling = false; installation = nil }
      do { try await package.install(); await refresh() }
      catch is CancellationError { await refresh() }
      catch let error as URLError where error.code == .cancelled { await refresh() }
      catch { failure = error.localizedDescription; await refresh() }
    }
  }
  func cancel() { installation?.cancel() }
  func remove() async {
    guard !isBusy() else { failure = "assessment.error.busy"; return }
    do { try await package.remove(); await refresh() }
    catch { failure = error.localizedDescription }
  }

  /// Installs the scorer for the chosen reference accent. UK practice is one engine: PhoneticXeus
  /// grades every phone and UK Reference measures delivery, so both packages are downloaded at
  /// onboarding. There is no UK Reference-only mode; a build without the runtime is an error.
  func installRequired(for accent: ReferenceAccent) async throws -> EngineID {
    switch accent {
    case .uk:
      guard let ukPackage else { throw ModelInstallationError.verificationFailed("UK Reference") }
      if !(await ukPackage.installed()) { try await ukPackage.install() }
      await refresh()
      guard ukInstalled else { throw ModelInstallationError.verificationFailed("UK Reference") }
      guard let xeusPackage, xeusAvailable else { throw ModelInstallationError.verificationFailed("PhoneticXeus") }
      if !xeusInstalled { try await xeusPackage.install() }
      await refresh()
      guard xeusReady else { throw ModelInstallationError.verificationFailed("PhoneticXeus") }
      return .phoneticXeus
    case .us:
      guard let phonePackage else { throw ModelInstallationError.verificationFailed("Phone Scorer") }
      if !(await phonePackage.installed()) { try await phonePackage.install() }
      await refresh()
      guard phoneInstalled else { throw ModelInstallationError.verificationFailed("Phone Scorer") }
      return .phone
    }
  }

  /// At launch on a machine that finished onboarding before the combined engine shipped in this
  /// build: download the missing weights and switch UK practice over to PhoneticXeus. A machine
  /// that deliberately runs another engine is not touched; a failed download stays in Settings.
  func adoptXeusIfNeeded(preferences: Preferences) async -> EngineID? {
    await refresh()
    guard preferences.accent == .uk, xeusAvailable, let xeusPackage,
      preferences.productionAssessmentEngine == .ukReference || preferences.productionAssessmentEngine == nil,
      !xeusInstalling, !ukInstalling else { return nil }
    if !xeusReady {
      xeusInstalling = true; xeusFailure = nil
      defer { xeusInstalling = false }
      do {
        if let ukPackage, !(await ukPackage.installed()) { try await ukPackage.install() }
        if !(await xeusPackage.installed()) { try await xeusPackage.install() }
      } catch { xeusFailure = error.localizedDescription; await refresh(); return nil }
      await refresh()
    }
    return xeusReady ? .phoneticXeus : nil
  }
}
extension EnvironmentValues {
  @Entry var pronunciationModelManager: PronunciationModelManager?
}
