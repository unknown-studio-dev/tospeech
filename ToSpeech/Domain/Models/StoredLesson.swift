import Foundation

enum LessonLifecycle: String, Codable, Sendable {
  case preparing
  case ready
  case failed
  case deleting
}

struct StoredLesson: Identifiable, Equatable, Sendable {
  var id: UUID
  var provider: String
  var externalID: String
  var sourceURL: URL?
  var title: String
  var author: String?
  var lifecycle: LessonLifecycle
  var generation: Int
  var createdAt: Date
  var updatedAt: Date
}

struct NewLesson: Equatable, Sendable {
  var id: UUID
  var provider: String
  var externalID: String
  var sourceURL: URL?
  var title: String
  var author: String?
  var createdAt: Date

  init(
    id: UUID = UUID(),
    provider: String,
    externalID: String,
    sourceURL: URL? = nil,
    title: String,
    author: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.provider = provider
    self.externalID = externalID
    self.sourceURL = sourceURL
    self.title = title
    self.author = author
    self.createdAt = createdAt
  }
}
