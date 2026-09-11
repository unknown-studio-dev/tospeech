import SwiftUI

/// Display-only examples for the app's component workbench.
enum DesignSystemFixtures {
  static let palette: [(String, Color, String)] = [
    ("Canvas", EchoTheme.canvas, "#151C2B"), ("Reading", EchoTheme.surface, "#1D2738"),
    ("Raised", EchoTheme.raised, "#263247"), ("Primary", EchoTheme.accent, "#C2B6E8"),
    ("Text", EchoTheme.text, "#F0F2F6"), ("Secondary", EchoTheme.secondaryText, "#B6C1D2"),
    ("Focus", EchoTheme.focus, "#A7C8FF"), ("Success", EchoTheme.success, "#C4D995"),
    ("Warning", EchoTheme.caution, "#E8C181"), ("Error", EchoTheme.danger, "#F0A5AA"),
  ]
  static let accents = [(id: "uk", title: "Anh Anh · UK"), (id: "us", title: "Anh Mỹ · US")]
  static let choices = [
    EchoChoice(
      id: "listen", title: "Nghe và bắt kịp câu",
      detail: "Luyện nghe từng câu, từng từ trước khi nói theo."),
    EchoChoice(
      id: "speak", title: "Nói rõ và tự nhiên hơn",
      detail: "Luyện phát âm, trọng âm và nhịp điệu của câu."),
  ]
  static let sentence: [(String, String?)] = [
    ("Sometimes", "/ˈsʌmtaɪmz/"), ("the", "/ðə/"), ("smallest", "/ˈsmɔːlɪst/"),
    ("step", "/step/"), ("makes", "/meɪks/"), ("a", "/ə/"), ("difference.", "/ˈdɪfrəns/"),
  ]
  static let translation = "Đôi khi, bước nhỏ nhất lại tạo nên sự khác biệt."
  static let ipaGlyphs = "θ ð ʃ ʒ ŋ ɪ ʊ ə ɜː æ ɑː ɔː ˈ ˌ tʃ dʒ əʊ aɪ n̩ l̩"
  static let disabledReason = "Chọn một câu trước khi lưu."
}
