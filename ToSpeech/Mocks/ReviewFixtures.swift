import Foundation

struct ReviewPriority: Identifiable, Sendable {
  var id: String { wordIDs.joined(separator: ":") + title }
  var title: String
  var titleCopy: EchoCopy?
  var explanation: String
  var explanationCopy: EchoCopy?
  var phoneme: String
  var wordIDs: [String]

  init(
    title: String, titleCopy: EchoCopy? = nil, explanation: String,
    explanationCopy: EchoCopy? = nil, phoneme: String, wordIDs: [String]
  ) {
    self.title = title
    self.titleCopy = titleCopy
    self.explanation = explanation
    self.explanationCopy = explanationCopy
    self.phoneme = phoneme
    self.wordIDs = wordIDs
  }
}

struct ReviewFeedback: Sendable {
  var summary: String
  var completeness: String
  var fluency: String
  var priorities: [ReviewPriority]
}

enum ReviewFixtures {
  static func inlineSummary(for sentence: LessonSentence) -> String {
    if sentence.text.localizedCaseInsensitiveContains("never thought it") {
      return "Đủ câu. Thử nối “thought it” liền hơn."
    }
    if sentence.text.localizedCaseInsensitiveContains("smallest changes") {
      return "Câu rõ. Thử nhấn “smallest changes” rõ hơn."
    }
    return "Đây là nhận xét mẫu, chưa phải đánh giá giọng nói thật. Nghe A/B để so sánh."
  }

  static func feedback(for sentence: LessonSentence) -> ReviewFeedback {
    if sentence.text.localizedCaseInsensitiveContains("never thought it") {
      return ReviewFeedback(
        summary: "The full sentence is present. Keep the middle phrase moving smoothly.",
        completeness: "All words present",
        fluency: "One extra pause",
        priorities: [
          priority(
            "Connect “thought it”", "Move directly from the final consonant into the short vowel.",
            "/θɔːt ɪt/", words: ["thought", "it"], in: sentence),
          priority(
            "Release the opening /θ/",
            "Compare the source and saved take before practising this sound again.", "/θ/",
            words: ["thought"], in: sentence),
        ]
      )
    }
    if sentence.text.localizedCaseInsensitiveContains("smallest changes") {
      return ReviewFeedback(
        summary: "The sentence stays clear; the strongest content words can stand out more.",
        completeness: "All words present",
        fluency: "Even pacing",
        priorities: [
          priority(
            "Stress “smallest changes”",
            "Give these content words more weight than the words around them.",
            "/ˈsmɔː.lɪst ˈtʃeɪn.dʒɪz/", words: ["smallest", "changes"], in: sentence)
        ]
      )
    }
    let target = sentence.words.max { clean($0.text).count < clean($1.text).count }
    let targetText = target.map { clean($0.text) } ?? "this phrase"
    return ReviewFeedback(
      summary: "Sentence-specific preview feedback. A validated engine result is still required.",
      completeness: "Fixture only",
      fluency: "Measurement unavailable",
      priorities: [
        ReviewPriority(
          title: "Inspect “\(targetText)” in context",
          titleCopy: EchoCopy("review.inspect_in_context", arguments: [.raw(targetText)]),
          explanation: "Compare the saved source span and take before practising again.",
          explanationCopy: EchoCopy("review.compare_saved_source_take"),
          phoneme: target?.ipaUK ?? "Unavailable", wordIDs: target.map { [$0.id] } ?? [])
      ]
    )
  }

  private static func priority(
    _ title: String, _ explanation: String, _ phoneme: String, words: [String],
    in sentence: LessonSentence
  ) -> ReviewPriority {
    let wanted = Set(words.map { $0.lowercased() })
    return ReviewPriority(
      title: title, explanation: explanation, phoneme: phoneme,
      wordIDs: sentence.words.filter { wanted.contains(clean($0.text).lowercased()) }.map(\.id))
  }

  private static func clean(_ text: String) -> String {
    text.trimmingCharacters(in: .punctuationCharacters)
  }
}
