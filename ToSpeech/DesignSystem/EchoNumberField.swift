import SwiftUI

/// A numeric adapter of EchoTextField, not a second input appearance.
/// Invalid drafts remain visible; only finite, parsed values reach the caller.
struct EchoNumberField: View {
  var label: String
  var value: Double
  var onCommit: (Double) -> Void
  @State private var draft = ""
  @State private var error: String?

  var body: some View {
    EchoTextField(
      label: label, text: $draft, helper: "Seconds",
      state: error.map { .error($0) } ?? .idle,
      onEndEditing: commit)
      .onSubmit(commit)
      .onAppear { sync() }
      .onChange(of: value) { sync() }
      .onChange(of: draft) { error = nil }
  }

  private func sync() {
    draft = value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
  }

  private func commit() {
    guard let number = Self.parse(draft) else {
      error = "Enter a valid time in seconds. Your draft is kept."
      return
    }
    onCommit(number)
  }

  static func parse(_ text: String, locale: Locale = .current) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
    guard let value = Double(normalized), value.isFinite else { return nil }
    return value
  }
}
