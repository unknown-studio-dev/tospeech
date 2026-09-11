import Foundation

enum ProductionImportRequest: Sendable, Equatable {
  case youtube(url: URL, titleOverride: String?)
  case localAudio(url: URL, securityScoped: Bool, titleOverride: String?)
}

enum ProductionImportPhase: String, Codable, CaseIterable, Sendable {
  case resolving
  case downloadingAudio
  case probing
  case fetchingCaptions
  case preparingTranscript
  case publishing
  case ready
  case failed
  case cancelled

  var isTerminal: Bool { [.ready, .failed, .cancelled].contains(self) }
}

struct ProductionImportJob: Identifiable, Equatable, Sendable {
  let id: UUID
  let lessonID: UUID
  let title: String
  let phase: ProductionImportPhase
  let runToken: UUID
  let expectedGeneration: Int
  let error: ProductionImportError?
  let createdAt: Date
  let updatedAt: Date
}

struct ImportCheckpoint: Codable, Equatable, Sendable {
  let phase: ProductionImportPhase
  let workspaceRelativePath: String
  let manifestRelativePath: String?
  let detail: String?
  let updatedAt: Date
}

struct StoredImportJob: Equatable, Sendable {
  let id: UUID
  let expectedGeneration: Int
  let inputJSON: String
  let runToken: UUID
  let checkpointJSON: String
  let status: String
}

struct ImportAttempt: Identifiable, Equatable, Sendable {
  let id: UUID
  let jobID: UUID
  let number: Int
  let runToken: UUID
  let status: String
  let startedAt: Date
  let finishedAt: Date?
}

struct DeletingLesson: Equatable, Sendable {
  let id: UUID
  let generation: Int
}

struct MediaAsset: Identifiable, Codable, Equatable, Sendable {
  enum Role: String, Codable, Sendable {
    case sourceAudio = "source_audio"
    case thumbnail
    case takeAudio = "take_audio"
    case caption, waveform
  }

  let id: UUID
  let lessonID: UUID
  let role: Role
  let relativePath: String
  let checksum: String
  let format: String?
  let sampleRate: Int?
  let frameCount: Int?
  let createdAt: Date
}

struct LibraryLessonSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let author: String?
  let lifecycle: LessonLifecycle
  let generation: Int
  let duration: TimeInterval?
  let thumbnailURL: URL?
  /// Present only for a validated YouTube import. Local media never creates a
  /// visual follower, and callers must not derive an embed URL from free text.
  let youtubeVisualSource: YouTubeVisualSource?
  /// A ready audio asset alone is not enough to enter production practice.
  /// This is true only when a current immutable segment revision exists.
  let isPracticeReady: Bool
  let preparedSentenceCount: Int
  let createdAt: Date
}

struct YouTubeVisualSource: Equatable, Sendable {
  let videoID: String
  let sourceURL: URL

  init?(provider: String, externalID: String, sourceURL: URL?) {
    guard provider.lowercased() == "youtube", let sourceURL,
      let parsedID = YouTubeLink.videoID(sourceURL.absoluteString), parsedID == externalID
    else { return nil }
    videoID = parsedID
    self.sourceURL = sourceURL
  }
}

enum ProductionImportError: Error, Equatable, LocalizedError, Sendable {
  case invalidYouTubeURL
  case inaccessibleLocalAudio
  case unsupportedMedia(String)
  case duplicateIdentity
  case toolchain(BundledImportToolchainError)
  case subprocess(SubprocessError)
  case cancelled
  case staleGeneration(expected: Int)
  case recoveryRequired(String)
  case persistence(String)

  var errorDescription: String? {
    switch self {
    case .invalidYouTubeURL: "Enter a valid public YouTube URL."
    case .inaccessibleLocalAudio: "The selected audio file is no longer accessible."
    case .unsupportedMedia(let detail): "The audio file cannot be imported: \(detail)"
    case .duplicateIdentity: "This lesson is already in your Library."
    case .toolchain(let error): error.localizedDescription
    case .subprocess(let error): error.localizedDescription
    case .cancelled: "Import cancelled."
    case .staleGeneration: "This lesson changed while the import was running."
    case .recoveryRequired(let detail): "Import recovery is required: \(detail)"
    case .persistence(let detail): "Local import data could not be saved: \(detail)"
    }
  }

  /// Short recovery copy for learner-facing surfaces. Detailed helper output is
  /// retained in the job checkpoint and logs, but must never be rendered into
  /// the Library banner.
  var presentationDescription: String {
    let technical = localizedDescription.lowercased()
    if technical.contains("http error 429") || technical.contains("too many requests") {
      return "YouTube is temporarily limiting downloads. Wait a little, then try again."
    }
    if technical.contains("sign in to confirm") || technical.contains("cookies-from-browser")
      || technical.contains("visitor data")
    {
      return
        "YouTube requires verification for this video. Try another public video or import an audio file."
    }
    switch self {
    case .invalidYouTubeURL, .inaccessibleLocalAudio, .duplicateIdentity, .cancelled,
      .staleGeneration:
      return localizedDescription
    case .unsupportedMedia:
      return "This source does not contain audio that EchoLab can prepare."
    case .toolchain:
      return "The local import tools are unavailable. Reopen EchoLab, then try again."
    case .subprocess, .recoveryRequired:
      return "EchoLab could not prepare this lesson. Try again or import an audio file."
    case .persistence:
      return "EchoLab could not save the import locally. Check free storage, then try again."
    }
  }
}
