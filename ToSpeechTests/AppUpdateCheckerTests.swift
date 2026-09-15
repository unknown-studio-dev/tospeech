import Foundation
import Testing
@testable import ToSpeech

@Suite("App update checker")
struct AppUpdateCheckerTests {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  private func release(version: String) -> String {
    """
    { "version": "\(version)", "build": "7", "notes": "Fixes", "minOS": "26.0",
      "downloadURL": "https://github.com/unknown-studio-dev/tospeech/releases/latest" }
    """
  }

  // MARK: AppVersion

  @Test func parsesAndStripsLeadingV() {
    #expect(AppVersion("v1.2.3")?.components == [1, 2, 3])
    #expect(AppVersion("0.1.0")?.components == [0, 1, 0])
    #expect(AppVersion("")?.components == nil)
    #expect(AppVersion("1.x.0") == nil)
  }

  @Test func comparesNumericallyNotLexically() {
    #expect(AppVersion("0.10.0")! > AppVersion("0.9.0")!)
    #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
    #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
    #expect(!(AppVersion("0.1.0")! > AppVersion("0.1.0")!))
  }

  // MARK: version.json decoding

  @Test func decodesReleaseInfo() throws {
    let info = try JSONDecoder().decode(AppReleaseInfo.self, from: data(release(version: "0.2.0")))
    #expect(info.version == "0.2.0")
    #expect(info.downloadURL == "https://github.com/unknown-studio-dev/tospeech/releases/latest")
  }

  // MARK: AppUpdateChecker states

  @Test @MainActor func reportsUpToDateWhenLatestEqualsCurrent() async {
    let checker = AppUpdateChecker(currentVersion: "0.2.0") { self.data(self.release(version: "0.2.0")) }
    await checker.check()
    #expect(checker.state == .upToDate)
  }

  @Test @MainActor func reportsAvailableWhenLatestIsNewer() async {
    let checker = AppUpdateChecker(currentVersion: "0.1.0") { self.data(self.release(version: "0.2.0")) }
    await checker.check()
    guard case .available(let info) = checker.state else { Issue.record("expected available"); return }
    #expect(info.version == "0.2.0")
  }

  @Test @MainActor func staysUpToDateWhenLatestIsOlder() async {
    let checker = AppUpdateChecker(currentVersion: "0.3.0") { self.data(self.release(version: "0.2.0")) }
    await checker.check()
    #expect(checker.state == .upToDate)
  }

  @Test @MainActor func failsOnMalformedJSON() async {
    let checker = AppUpdateChecker(currentVersion: "0.1.0") { self.data("not json") }
    await checker.check()
    #expect(checker.state == .failed)
  }

  @Test @MainActor func failsOnNetworkError() async {
    let checker = AppUpdateChecker(currentVersion: "0.1.0") { throw URLError(.notConnectedToInternet) }
    await checker.check()
    #expect(checker.state == .failed)
  }

  @Test @MainActor func checkOnAppearRunsOnlyOncePerLaunch() async {
    var calls = 0
    let checker = AppUpdateChecker(currentVersion: "0.1.0") {
      calls += 1
      return self.data(self.release(version: "0.1.0"))
    }
    await checker.checkOnAppear()
    await checker.checkOnAppear()
    #expect(calls == 1)
    // Manual re-check always runs.
    await checker.check()
    #expect(calls == 2)
  }
}
