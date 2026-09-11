import Foundation

enum ImportPhase: String { case preparing, ready, failed, cancelled }
struct PreviewImportJob: Identifiable {
  var id: UUID
  var input: String
  var title: String
  var captions: String
  var translate: Bool
  var phase: ImportPhase = .preparing
  var step = 0
  var error: String?
  var lessonID: String?
  static let steps = [
    "Reading video details", "Preparing source audio", "Aligning transcript", "Looking up IPA",
    "Preparing Vietnamese translation",
  ]
}

enum YouTubeLink {
  static func videoID(_ input: String) -> String? {
    guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased()
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    let id: String?
    if host == "youtu.be" {
      id = parts.first
    } else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) {
      if parts.first == "watch" {
        id =
          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "v"
          }?.value
      } else if ["shorts", "embed", "live"].contains(parts.first ?? "") {
        id = parts.dropFirst().first
      } else {
        id = nil
      }
    } else {
      id = nil
    }
    guard let id, id.count == 11,
      id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { return nil }
    return id
  }
}

extension EchoStore {
  func startImport(
    input: String, title: String, captions: String = "Prefer creator captions",
    translate: Bool = true, simulateFailure: Bool = false, localFile: Bool = false
  ) {
    guard importJob?.phase != .preparing else { return }
    guard localFile || YouTubeLink.videoID(input) != nil else {
      message = EchoCopy("Enter a valid YouTube video link.")
      return
    }
    if let id = YouTubeLink.videoID(input),
      let existing = lessons.first(where: { $0.sourceURL.flatMap(YouTubeLink.videoID) == id })
    {
      openLesson(existing.id)
      message = EchoCopy("This video is already in your library.")
      return
    }
    let defaultTitle = EchoLocalization.string(
      "Imported lesson · preview", locale: preferences.language.locale)
    let job = PreviewImportJob(
      id: UUID(), input: input, title: title.isEmpty ? defaultTitle : title,
      captions: captions, translate: translate)
    importJob = job
    importTask = Task { [weak self] in
      for step in 0..<PreviewImportJob.steps.count {
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        guard let self, self.importJob?.id == job.id, self.importJob?.phase == .preparing else {
          return
        }
        if simulateFailure && step == 2 {
          self.importJob?.phase = .failed
          self.importJob?.error = "Simulated preparation failure. Your input is preserved."
          return
        }
        self.importJob?.step = step
      }
      guard let self, self.importJob?.id == job.id, self.importJob?.phase == .preparing else {
        return
      }
      let id = UUID().uuidString
      var lesson = LessonFixtures.lesson(
        id: id, title: job.title, sourceURL: localFile ? nil : input)
      if !translate {
        for index in lesson.sentences.indices { lesson.sentences[index].translation = "" }
      }
      self.lessons.insert(lesson, at: 0)
      self.importJob?.phase = .ready
      self.importJob?.lessonID = id
    }
  }
  func cancelImport() {
    importTask?.cancel()
    importJob?.phase = .cancelled
  }
  func retryImport() {
    guard let job = importJob, job.phase != .preparing else { return }
    startImport(
      input: job.input, title: job.title, captions: job.captions, translate: job.translate,
      localFile: YouTubeLink.videoID(job.input) == nil)
  }
}
