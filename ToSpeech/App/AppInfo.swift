import Foundation

/// Author, copyright and the release feed, plus the shipping version read from the bundle.
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` are the single source of
/// truth; `make bump` moves them together with `version.json` so the feed can never disagree.
enum AppInfo {
  static let author = "Unknown Studio (pirumu)"
  static let copyright = "© 2026 Unknown Studio (pirumu)"
  static let studioURL = URL(string: "https://unknownstudio.dev")!

  /// A stable permalink to the current release's `version.json` asset — no GitHub API call.
  static let updateFeedURL = URL(
    string: "https://github.com/unknown-studio-dev/tospeech/releases/latest/download/version.json")!
  /// Fallback download page when a release omits its own `downloadURL`.
  static let releasesURL = URL(
    string: "https://github.com/unknown-studio-dev/tospeech/releases/latest")!

  static var displayName: String {
    bundleString("CFBundleDisplayName") ?? bundleString("CFBundleName") ?? "ToSpeech"
  }
  static var version: String { bundleString("CFBundleShortVersionString") ?? "0.0.0" }
  static var build: String { bundleString("CFBundleVersion") ?? "0" }

  private static func bundleString(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}
