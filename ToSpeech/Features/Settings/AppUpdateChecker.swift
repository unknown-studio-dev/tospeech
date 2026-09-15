import Foundation
import OSLog
import SwiftUI

/// A dotted release version (e.g. `0.1.0`), compared numerically so `0.10` beats `0.9`.
struct AppVersion: Comparable, Equatable {
  let components: [Int]

  init?(_ string: String) {
    let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    components = parts.compactMap { $0 }
  }

  static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  /// Consistent with `<`: trailing zeros don't matter, so `1.0` equals `1.0.0`.
  static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }
}

/// `version.json`, attached as an asset to the latest GitHub release. `AppInfo.updateFeedURL`
/// resolves to whichever release is current, so the checker only ever reads this shape.
struct AppReleaseInfo: Codable, Equatable, Sendable {
  let version: String
  var build: String?
  var notes: String?
  var minOS: String?
  var downloadURL: String
}

/// Checks the published release feed and reports whether a newer build exists. It never
/// downloads or installs — the UI opens the release page in the browser. The fetcher is
/// injected so tests cover every outcome without the network, and it is left unset (nil in
/// the environment) under preview fixtures, render and test runs so no request is made.
@MainActor @Observable
final class AppUpdateChecker {
  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppReleaseInfo)
    case failed
  }

  private(set) var state: State = .idle
  let currentVersion: String
  private let fetch: () async throws -> Data
  private var hasCheckedThisLaunch = false

  init(
    currentVersion: String = AppInfo.version,
    fetch: @escaping () async throws -> Data = AppUpdateChecker.liveFetch
  ) {
    self.currentVersion = currentVersion
    self.fetch = fetch
  }

  /// Runs the first time the About section appears, then stays quiet for the launch.
  func checkOnAppear() async {
    guard !hasCheckedThisLaunch else { return }
    await check()
  }

  func check() async {
    hasCheckedThisLaunch = true
    state = .checking
    do {
      let data = try await fetch()
      let info = try JSONDecoder().decode(AppReleaseInfo.self, from: data)
      guard let latest = AppVersion(info.version), let current = AppVersion(currentVersion) else {
        Logger.updates.error("Unparseable version: feed=\(info.version, privacy: .public) current=\(self.currentVersion, privacy: .public)")
        state = .failed
        return
      }
      state = latest > current ? .available(info) : .upToDate
    } catch {
      Logger.updates.error("Update check failed: \(error.localizedDescription, privacy: .public)")
      state = .failed
    }
  }

  static func liveFetch() async throws -> Data {
    var request = URLRequest(url: AppInfo.updateFeedURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }
}

extension Logger {
  fileprivate static let updates = Logger(subsystem: "com.unknownstudio.tospeech", category: "Updates")
}

extension EnvironmentValues {
  @Entry var appUpdateChecker: AppUpdateChecker?
}
