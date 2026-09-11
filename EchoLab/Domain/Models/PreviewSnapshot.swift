import Foundation

enum AppRoute: String, CaseIterable, Identifiable {
  case library, shadowing, progress, settings
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .library: "books.vertical"
    case .shadowing: "headphones"
    case .progress: "chart.bar.xaxis"
    case .settings: "gearshape"
    }
  }
}

// Preview persistence only. Production revisions and assets are specified separately.
struct PreviewSnapshot: Codable, Sendable {
  var schemaVersion = 1
  var lessons: [Lesson]
  var takes: [PracticeTake]
  var preferences: Preferences
  var packages: [ModelPackage]
  var selectedLessonID: String?
  var selectedSentenceID: String?
}
