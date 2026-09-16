import Foundation
import Observation
import Speech
@preconcurrency import Translation

enum OnboardingSetupError: LocalizedError, Equatable, EchoCopyConvertible {
  /// Names are catalog keys ("gói dịch") or proper nouns ("Parakeet").
  case missingDependency(String)
  case verificationFailed(String)

  var copy: EchoCopy {
    switch self {
    case .missingDependency(let name): EchoCopy("onboarding.error.missing", arguments: [.localized(name)])
    case .verificationFailed(let name): EchoCopy("onboarding.error.verify", arguments: [.localized(name)])
    }
  }

  var errorDescription: String? { copy.resolve(locale: .current) }

}

enum OnboardingSetupState: Equatable, Sendable {
  case waiting, running, ready, failed

  var isReady: Bool { self == .ready }
}

struct OnboardingSetupItem: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  var detail: EchoCopy
  var state: OnboardingSetupState
}

@MainActor @Observable
final class OnboardingSetupModel {
  private let parakeetModels: ParakeetModelManager?
  private let pronunciationModels: PronunciationModelManager?
  private let alignmentModels: AlignmentModelManager?
  private let storageReady: Bool
  /// False when the learner reads no translation: the package step disappears.
  var includesTranslation = true
  var items: [OnboardingSetupItem] { allItems.filter { includesTranslation || $0.id != "translation" } }
  private var allItems: [OnboardingSetupItem] = [
    .init(id: "storage", title: "Dữ liệu cục bộ", detail: EchoCopy("Kiểm tra thư mục và cơ sở dữ liệu"), state: .waiting),
    .init(id: "transcription", title: "Nhận dạng giọng nói", detail: EchoCopy("Cài engine transcript đang chọn"), state: .waiting),
    .init(id: "apple-speech", title: "Apple Speech", detail: EchoCopy("Chuẩn bị gói tiếng Anh trên máy"), state: .waiting),
    .init(id: "translation", title: "Gói dịch", detail: EchoCopy("Chuẩn bị gói dịch offline"), state: .waiting),
    .init(id: "assessment", title: "Đánh giá phát âm", detail: EchoCopy("Cài bộ chấm phù hợp với giọng tham khảo"), state: .waiting),
  ]
  private(set) var isRunning = false
  var isComplete: Bool { items.allSatisfy { $0.state.isReady } }
  private(set) var failure: EchoCopy?

  init(
    parakeetModels: ParakeetModelManager?,
    pronunciationModels: PronunciationModelManager?,
    alignmentModels: AlignmentModelManager? = nil,
    storageReady: Bool
  ) {
    self.parakeetModels = parakeetModels
    self.pronunciationModels = pronunciationModels
    self.alignmentModels = alignmentModels
    self.storageReady = storageReady
  }

  func run(using translationSession: TranslationSession?, store: EchoStore) async {
    guard !isRunning, !isComplete else { return }
    isRunning = true
    failure = nil
    resetUnfinishedItems()
    do {
      try Task.checkCancellation()
      update("storage", state: .running, detail: EchoCopy("Đang kiểm tra dữ liệu cục bộ…"))
      guard storageReady else {
        throw OnboardingSetupError.missingDependency("dữ liệu cục bộ")
      }
      succeed("storage", EchoCopy("Đã sẵn sàng"))

      try await perform("transcription", runningDetail: "Đang tải và xác minh model…") {
        guard let parakeetModels else {
          throw OnboardingSetupError.missingDependency("Parakeet")
        }
        try await parakeetModels.installRequired()
        store.preferences.transcriptionEngine = "parakeet"
        // Word alignment backs word-level timing for every practice session, regardless of
        // reference accent, so it downloads unconditionally alongside Parakeet.
        guard let alignmentModels else {
          throw OnboardingSetupError.missingDependency("Word Alignment")
        }
        try await alignmentModels.installRequired()
      }

      try await perform("apple-speech", runningDetail: "Đang chuẩn bị gói ngôn ngữ…") {
        let locale = store.preferences.accent == .uk ? "en-GB" : "en-US"
        let module = try await AppleSpeechAnalyzerTranscriber.module(localeIdentifier: locale)
        try await AppleSpeechAnalyzerTranscriber.installAssets(for: module)
      }

      // The two download steps fail on transient conditions (network hiccups, the
      // system language-asset install finishing after prepareTranslation returns,
      // a Settings install racing the same package), so they retry on their own.
      if includesTranslation {
        try await perform("translation", runningDetail: "Đang chuẩn bị bản dịch offline…", attempts: 3) {
          guard let translationSession else { throw OnboardingSetupError.missingDependency("gói dịch") }
          try await translationSession.prepareTranslation()
          for _ in 0..<8 where !(await translationSession.isReady) {
            try await Task.sleep(for: .seconds(1))
          }
          guard await translationSession.isReady else {
            throw OnboardingSetupError.verificationFailed("gói dịch")
          }
        }
      }

      try await perform("assessment", runningDetail: "Đang tải và xác minh bộ chấm…", attempts: 3) {
        guard let pronunciationModels else {
          throw OnboardingSetupError.missingDependency("đánh giá phát âm")
        }
        for _ in 0..<60 where pronunciationModels.ukInstalling || pronunciationModels.phoneInstalling {
          try await Task.sleep(for: .seconds(1))
        }
        let engine = try await pronunciationModels.installRequired(for: store.preferences.accent)
        store.preferences.productionAssessmentEngine = engine
      }

    } catch is CancellationError {
      failCurrent(EchoCopy("Thiết lập đã bị gián đoạn. Hãy thử lại."))
    } catch {
      failCurrent(EchoCopy.describing(error))
    }
    isRunning = false
  }

  private func perform(
    _ id: String, runningDetail: String, attempts: Int = 1, operation: () async throws -> Void
  ) async throws {
    update(id, state: .running, detail: EchoCopy(runningDetail))
    try Task.checkCancellation()
    try await Self.withRetries(attempts: attempts, operation: operation) { [weak self] error, next in
      self?.update(id, state: .running, detail: EchoCopy("onboarding.retrying", arguments: [
        .nested(EchoCopy.describing(error)), .raw("\(next)"), .raw("\(attempts)"),
      ]))
    }
    succeed(id, EchoCopy("Đã tải và xác minh"))
  }

  /// Runs `operation` up to `attempts` times with a growing pause. Cancellation is
  /// never retried; the last error is rethrown.
  static func withRetries(
    attempts: Int, delay: Duration = .seconds(2),
    operation: () async throws -> Void,
    onRetry: (_ error: Error, _ nextAttempt: Int) -> Void = { _, _ in }
  ) async throws {
    for attempt in 1...max(1, attempts) {
      do {
        try await operation()
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard attempt < attempts else { throw error }
        onRetry(error, attempt + 1)
        try await Task.sleep(for: delay * attempt)
      }
    }
  }

  private func succeed(_ id: String, _ detail: EchoCopy) {
    update(id, state: .ready, detail: detail)
  }

  private func update(_ id: String, state: OnboardingSetupState, detail: EchoCopy) {
    guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
    allItems[index].state = state
    allItems[index].detail = detail
  }

  private func failCurrent(_ message: EchoCopy) {
    failure = message
    if let index = allItems.firstIndex(where: { $0.state == .running }) {
      allItems[index].state = .failed
      allItems[index].detail = message
    }
  }

  private func resetUnfinishedItems() {
    for index in allItems.indices where allItems[index].state != .ready {
      allItems[index].state = .waiting
    }
  }
}
