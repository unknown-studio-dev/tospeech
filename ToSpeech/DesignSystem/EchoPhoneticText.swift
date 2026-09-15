import SwiftUI

struct EchoPhoneticRun {
  let text: String
  let color: Color
  let linkID: Int?
}

/// One continuous native text run: no per-phone buttons, padding or split IPA tiles.
struct EchoPhoneticText: View {
  let runs: [EchoPhoneticRun]
  var size: CGFloat = 18
  var onSelect: (Int) -> Void
  var body: some View {
    Text(attributed).font(EchoFont.body(size: size)).fixedSize()
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "tospeech-phone", let id = Int(url.host ?? "") else { return .discarded }
        onSelect(id)
        return .handled
      })
  }
  private var attributed: AttributedString {
    var result = AttributedString()
    for run in runs {
      var value = AttributedString(run.text)
      value.foregroundColor = run.color
      if let id = run.linkID { value.link = URL(string: "tospeech-phone://\(id)") }
      result.append(value)
    }
    return result
  }
}
