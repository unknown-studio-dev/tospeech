import Foundation
import SwiftUI

enum EchoLocalization {
  static func string(_ key: String, locale: Locale, bundle: Bundle = .main) -> String {
    let language = locale.language.languageCode?.identifier ?? locale.identifier
    guard let path = bundle.path(forResource: language, ofType: "lproj"),
      let localizedBundle = Bundle(path: path)
    else { return key }
    return localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(
    _ key: String, locale: Locale, arguments: [CVarArg], bundle: Bundle = .main
  ) -> String {
    String(format: string(key, locale: locale, bundle: bundle), locale: locale, arguments: arguments)
  }
}

indirect enum EchoCopyArgument: Equatable, Sendable {
  case raw(String)
  case localized(String)
  /// Another piece of copy with its own arguments, resolved in the same locale.
  case nested(EchoCopy)

  fileprivate func resolve(locale: Locale, bundle: Bundle) -> String {
    switch self {
    case .raw(let value): value
    case .localized(let key): EchoLocalization.string(key, locale: locale, bundle: bundle)
    case .nested(let copy): copy.resolve(locale: locale, bundle: bundle)
    }
  }
}

/// Errors that know how to present themselves in the app language.
protocol EchoCopyConvertible {
  var copy: EchoCopy { get }
}

/// Keeps user-facing preview messages as localization keys until they are rendered.
/// Visible status and error copy can therefore update when the app language changes.
struct EchoCopy: Equatable, Sendable {
  let key: String
  var arguments: [EchoCopyArgument] = []

  init(_ key: String) { self.key = key }

  init(_ key: String, arguments: [EchoCopyArgument]) {
    self.key = key
    self.arguments = arguments
  }

  /// Localised copy for known errors; anything else is shown verbatim as a detail.
  static func describing(_ error: Error) -> EchoCopy {
    (error as? EchoCopyConvertible)?.copy
      ?? EchoCopy("storage.detail", arguments: [.raw(error.localizedDescription)])
  }

  func resolve(locale: Locale, bundle: Bundle = .main) -> String {
    guard !arguments.isEmpty else {
      return EchoLocalization.string(key, locale: locale, bundle: bundle)
    }
    return String(
      format: EchoLocalization.string(key, locale: locale, bundle: bundle), locale: locale,
      arguments: arguments.map { $0.resolve(locale: locale, bundle: bundle) })
  }
}

/// Localizes labels that travel through shared controls as runtime `String` values.
/// Lesson titles, transcripts and user-entered values simply fall back to themselves.
struct EchoLocalizedText: View {
  let copy: EchoCopy
  @Environment(\.locale) private var locale

  init(_ key: String) { copy = EchoCopy(key) }
  init(_ copy: EchoCopy) { self.copy = copy }

  var body: some View {
    Text(verbatim: copy.resolve(locale: locale))
  }
}

extension View {
  func echoAccessibilityLabel(_ key: String) -> some View {
    modifier(EchoLocalizedCopyModifier(key: key, kind: .label))
  }

  func echoAccessibilityHint(_ key: String) -> some View {
    modifier(EchoLocalizedCopyModifier(key: key, kind: .hint))
  }

  func echoAccessibilityValue(_ key: String) -> some View {
    modifier(EchoLocalizedCopyModifier(key: key, kind: .value))
  }

  func echoHelp(_ key: String) -> some View {
    modifier(EchoLocalizedCopyModifier(key: key, kind: .help))
  }

  func echoHelp(_ copy: EchoCopy) -> some View {
    modifier(EchoResolvedCopyModifier(copy: copy, kind: .help))
  }
}

private struct EchoLocalizedCopyModifier: ViewModifier {
  enum Kind { case label, hint, value, help }

  let key: String
  let kind: Kind
  @Environment(\.locale) private var locale

  @ViewBuilder func body(content: Content) -> some View {
    let value = EchoLocalization.string(key, locale: locale)
    switch kind {
    case .label: content.accessibilityLabel(value)
    case .hint: content.accessibilityHint(value)
    case .value: content.accessibilityValue(value)
    case .help: content.help(value)
    }
  }
}

private struct EchoResolvedCopyModifier: ViewModifier {
  let copy: EchoCopy
  let kind: EchoLocalizedCopyModifier.Kind
  @Environment(\.locale) private var locale

  @ViewBuilder func body(content: Content) -> some View {
    let value = copy.resolve(locale: locale)
    switch kind {
    case .label: content.accessibilityLabel(value)
    case .hint: content.accessibilityHint(value)
    case .value: content.accessibilityValue(value)
    case .help: content.help(value)
    }
  }
}
