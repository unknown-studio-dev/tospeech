import Foundation

/// The transcription models a user can install. Selection lives in Settings,
/// not at import time. `whisperKitModel` is the identifier passed to
/// `WhisperKitConfig(model:)`; `.en` variants are English-only (more accurate
/// than same-size multilingual) and handle US and UK accents alike — model
/// choice is a size/accuracy knob, not an accent switch.
enum WhisperModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
  case tiny
  case base
  case small
  case large

  var id: String { rawValue }

  static let `default`: WhisperModelVariant = .small

  var whisperKitModel: String {
    switch self {
    case .tiny: "tiny.en"
    case .base: "base.en"
    case .small: "small.en"
    case .large: "large-v3"
    }
  }

  /// A neutral model identifier (a proper name, not translated). The Settings
  /// UI adds any localized descriptor around it.
  var displayName: String {
    switch self {
    case .tiny: "Tiny"
    case .base: "Base"
    case .small: "Small"
    case .large: "Large v3"
    }
  }

  /// Approximate Core ML download footprint, for the Settings list only.
  var approximateDownloadBytes: Int64 {
    switch self {
    case .tiny: 75 * 1_000_000
    case .base: 145 * 1_000_000
    case .small: 480 * 1_000_000
    case .large: 1_500 * 1_000_000
    }
  }
}

enum WhisperModelCatalog {
  /// Stored in `engine_releases.engine_key` to scope transcription models.
  static let engineKey = "whisper-transcription"
  static var all: [WhisperModelVariant] { WhisperModelVariant.allCases }
}
