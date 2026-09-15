import SwiftUI

/// Explicit task state; hover, pressed and keyboard focus remain independent.
enum EchoControlState: Equatable {
  case idle
  case loading(String)
  case disabled(String)
  case error(String)
  case success(String)

  var message: String? {
    switch self {
    case .idle: nil
    case .loading(let value), .disabled(let value), .error(let value), .success(let value): value
    }
  }
  var blocksAction: Bool {
    switch self {
    case .disabled, .loading: true
    default: false
    }
  }
  var isLoading: Bool { if case .loading = self { true } else { false } }
}
