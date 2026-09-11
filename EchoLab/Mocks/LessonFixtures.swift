import Foundation

enum LessonFixtures {
  // Synthetic transcript and timings, exclusively for interaction previews.
  static let lines: [(String, String, String, String)] = [
    (
      "Sometimes, the smallest changes matter most.",
      "Đôi khi, những thay đổi nhỏ nhất lại quan trọng nhất.",
      "ˈsʌmtaɪmz|ðə|ˈsmɔːlɪst|ˈtʃeɪndʒɪz|ˈmætə|məʊst",
      "ˈsʌmtaɪmz|ðə|ˈsmɔlɪst|ˈtʃeɪndʒɪz|ˈmætɚ|moʊst"
    ),
    (
      "I never thought it would make such a difference.",
      "Tôi chưa bao giờ nghĩ rằng nó lại có thể tạo ra khác biệt lớn đến vậy.",
      "aɪ|ˈnevə|θɔːt|ɪt|wʊd|meɪk|sʌtʃ|ə|ˈdɪfərəns", "aɪ|ˈnevɚ|θɑt|ɪt|wʊd|meɪk|sʌtʃ|ə|ˈdɪfərəns"
    ),
    (
      "It changed the way I approached each day.", "Nó thay đổi cách tôi bắt đầu mỗi ngày.",
      "ɪt|tʃeɪndʒd|ðə|weɪ|aɪ|əˈprəʊtʃt|iːtʃ|deɪ", "ɪt|tʃeɪndʒd|ðə|weɪ|aɪ|əˈproʊtʃt|itʃ|deɪ"
    ),
    (
      "You do not have to get everything right.", "Bạn không cần phải làm đúng mọi thứ.",
      "juː|duː|nɒt|hæv|tə|ɡet|ˈevriθɪŋ|raɪt", "ju|du|nɑt|hæv|tə|ɡet|ˈevriθɪŋ|raɪt"
    ),
    (
      "Just take a moment and listen carefully.",
      "Hãy dành một chút thời gian và lắng nghe thật kỹ.",
      "dʒʌst|teɪk|ə|ˈməʊmənt|ənd|ˈlɪsən|ˈkeəfəli", "dʒʌst|teɪk|ə|ˈmoʊmənt|ənd|ˈlɪsən|ˈkerfəli"
    ),
    (
      "The important thing is to keep going.", "Điều quan trọng là tiếp tục cố gắng.",
      "ði|ɪmˈpɔːtənt|θɪŋ|ɪz|tə|kiːp|ˈɡəʊɪŋ", "ði|ɪmˈpɔrtənt|θɪŋ|ɪz|tə|kip|ˈɡoʊɪŋ"
    ),
  ]
  static func lesson(
    id: String, title: String, thumbnail: String = "conversation", duration: Double = 702,
    accent: ReferenceAccent = .uk, sourceURL: String? = nil
  ) -> Lesson {
    let sentences = (0..<42).map { index -> LessonSentence in
      let line = lines[(index + 2) % lines.count]
      let words = line.0.split(separator: " ").map(String.init)
      let uk = line.2.split(separator: "|").map(String.init)
      let us = line.3.split(separator: "|").map(String.init)
      let start = 3 + Double(index) * min(15, (duration - 8) / 41)
      let end = min(duration, start + 4.8)
      let sid = "\(id)-s\(index + 1)"
      let tokens = words.enumerated().map { offset, word in
        LessonWord(
          id: "\(sid)-w\(offset)", text: word,
          ipaUK: uk.indices.contains(offset) ? "/\(uk[offset])/" : nil,
          ipaUS: us.indices.contains(offset) ? "/\(us[offset])/" : nil,
          span: AudioSpan(
            start: start + Double(offset) * 4.8 / Double(words.count),
            end: min(end, start + Double(offset + 1) * 4.8 / Double(words.count))))
      }
      return LessonSentence(
        id: sid, number: index + 1, text: line.0, translation: line.1,
        span: AudioSpan(start: start, end: end), words: tokens)
    }
    return Lesson(
      id: id, title: title, author: "English conversation", thumbnail: thumbnail,
      duration: duration, accent: accent, sourceURL: sourceURL, createdAt: Date(),
      sentences: sentences)
  }
  static func lessons() -> [Lesson] {
    [
      lesson(id: "small-changes", title: "Small changes, big difference", thumbnail: "microphone"),
      lesson(id: "conversation", title: "The art of a good conversation", duration: 484),
      lesson(
        id: "rhythm", title: "Finding your own rhythm", thumbnail: "rhythm", duration: 617,
        accent: .us),
      lesson(id: "story", title: "A story worth telling", thumbnail: "story", duration: 729),
    ]
  }
}
