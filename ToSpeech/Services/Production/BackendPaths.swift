import Foundation

struct BackendPaths: Equatable, Sendable {
  let root: URL

  static var live: Self {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return Self(
      root: applicationSupport.appendingPathComponent("ToSpeech/Production", isDirectory: true))
  }

  var database: URL { root.appendingPathComponent("tospeech.sqlite3") }
  var sourceAudio: URL { root.appendingPathComponent("Media/SourceAudio", isDirectory: true) }
  var thumbnails: URL { root.appendingPathComponent("Media/Thumbnails", isDirectory: true) }
  var takeStaging: URL { root.appendingPathComponent("Takes/Staging", isDirectory: true) }
  var finalTakes: URL { root.appendingPathComponent("Takes/Final", isDirectory: true) }
  var deletingTakes: URL { root.appendingPathComponent("Takes/Deleting", isDirectory: true) }
  var packages: URL { root.appendingPathComponent("Packages", isDirectory: true) }
  var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }

  var importJobs: URL { cache.appendingPathComponent("ImportJobs", isDirectory: true) }

  func importWorkspace(for jobID: UUID) -> URL {
    importJobs.appendingPathComponent(jobID.uuidString, isDirectory: true)
  }

  func deletionManifest(for lessonID: UUID) -> URL {
    importJobs.appendingPathComponent("delete-\(lessonID.uuidString).json", isDirectory: false)
  }

  func prepare(using fileManager: FileManager = .default) throws {
    for directory in [root, sourceAudio, thumbnails, takeStaging, finalTakes, deletingTakes,
      packages, cache, importJobs] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }
}
