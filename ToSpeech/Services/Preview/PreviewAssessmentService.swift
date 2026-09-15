import Foundation

extension EchoStore {
  func requestAssessment(takeID: String) {
    guard let engine = preferences.activeEngine,
      let i = takes.firstIndex(where: { $0.id == takeID }),
      [.complete, .earlyStop].contains(takes[i].outcome), !switchingEngine,
      packages.contains(where: { $0.id == engine && $0.status == .installed })
    else { return }
    guard !takes[i].assessments.contains(where: { [.queued, .running].contains($0.status) }) else {
      return
    }
    takes[i].assessments.append(
      PreviewFixtures.assessment(engine: engine, accent: preferences.accent))
    drainAssessmentQueue()
  }
  func retryAssessment(takeID: String, assessmentID: String) {
    guard let i = takes.firstIndex(where: { $0.id == takeID }),
      let j = takes[i].assessments.firstIndex(where: { $0.id == assessmentID }),
      takes[i].assessments[j].status == .failed
    else { return }
    let engine = takes[i].assessments[j].engine
    guard preferences.activeEngine == engine,
      packages.contains(where: { $0.id == engine && $0.status == .installed })
    else {
      message = EchoCopy(
        "assessment.activate_before_retry", arguments: [.raw(engine.title)])
      return
    }
    takes[i].assessments[j].status = .queued
    takes[i].assessments[j].error = nil
    drainAssessmentQueue()
  }
  func cancelAssessments() {
    assessmentTask?.cancel()
    assessmentTask = nil
    for i in takes.indices {
      for j in takes[i].assessments.indices
      where [.queued, .running].contains(takes[i].assessments[j].status) {
        takes[i].assessments[j].status = .cancelled
      }
    }
  }
  private func drainAssessmentQueue() {
    guard assessmentTask == nil else { return }
    assessmentTask = Task { [weak self] in
      while let self,
        let take = self.takes.first(where: { $0.assessments.contains { $0.status == .queued } }),
        let assessment = take.assessments.first(where: { $0.status == .queued })
      {
        self.updateAssessment(take.id, assessment.id) { $0.status = .running }
        do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
        guard !Task.isCancelled else { return }
        let fail = self.failNextAssessment
        self.failNextAssessment = false
        self.updateAssessment(take.id, assessment.id) {
          $0.status = fail ? .failed : .complete
          $0.score = fail ? nil : PreviewFixtures.simulatedAssessmentScore
          $0.error = fail ? "Simulated assessment failure. Your take is retained." : nil
        }
      }
      self?.assessmentTask = nil
    }
  }
  private func updateAssessment(
    _ takeID: String, _ assessmentID: String, update: (inout AssessmentResult) -> Void
  ) {
    guard let i = takes.firstIndex(where: { $0.id == takeID }),
      let j = takes[i].assessments.firstIndex(where: { $0.id == assessmentID })
    else { return }
    update(&takes[i].assessments[j])
  }
  func activateEngine(_ id: EngineID?) {
    guard pendingAssessmentCount == 0, !switchingEngine else {
      message = EchoCopy("Finish or cancel queued assessments before switching.")
      return
    }
    if let id {
      guard packages.contains(where: { $0.id == id && $0.status == .installed }) else { return }
    }
    preferences.activeEngine = id
  }
  func removePackage(_ id: EngineID) {
    guard preferences.activeEngine != id, pendingAssessmentCount == 0,
      let i = packages.firstIndex(where: { $0.id == id })
    else { return }
    packages[i].status = packages[i].available ? .notInstalled : .unavailable
    message = EchoCopy("Preview package removed. Recordings and scores are retained.")
  }
  func downloadPackage(_ id: EngineID, simulateFailure: Bool = false) {
    guard let i = packages.firstIndex(where: { $0.id == id }), packages[i].available,
      [.notInstalled, .failed].contains(packages[i].status)
    else { return }
    packages[i].status = .downloading
    packages[i].progress = 0
    packages[i].error = nil
    packageTasks[id] = Task { [weak self] in
      for step in 1...5 {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, let index = self.packages.firstIndex(where: { $0.id == id }) else { return }
        if simulateFailure && step == 3 {
          self.packages[index].status = .failed
          self.packages[index].error = "Simulated download failure."
          return
        }
        self.packages[index].progress = Double(step) / 5
      }
      guard let self, let index = self.packages.firstIndex(where: { $0.id == id }) else { return }
      self.packages[index].status = .verifying
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard !Task.isCancelled else { return }
      self.packages[index].status = .installed
    }
  }
  func cancelPackageDownload(_ id: EngineID) {
    packageTasks[id]?.cancel()
    packageTasks[id] = nil
    if let i = packages.firstIndex(where: { $0.id == id }) {
      packages[i].status = .notInstalled
      packages[i].progress = 0
    }
  }
}
