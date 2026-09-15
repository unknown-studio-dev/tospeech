#if DEBUG
import Foundation

enum AssessedReviewFixtures {
  static func make() throws -> (PracticeTake, PronunciationJob) {
    let matching = try ContentMatchingFixtures.job(status: .complete)
    let pairs = [("I", "aɪ"), ("never", "ˈnevə"), ("thought", "θɔːt"), ("it", "ɪt"),
      ("would", "wʊd"), ("make", "meɪk"), ("such", "sʌtʃ"), ("a", "ə"), ("difference.", "ˈdɪfərəns")]
    let targets = pairs.enumerated().map { index, pair in
      PronunciationWordTarget(id: "fixture-word-\(index)", text: pair.0, variants: [pair.1],
        dictionarySources: ["Design fixture"], sourceStart: Double(index)*0.44, sourceEnd: Double(index+1)*0.44)
    }
    let words = targets.enumerated().map { index, target -> WordPronunciationEvidence in
      let phones = PhoneInventory.parse(target.variants[0])!.enumerated().map { j, symbol -> PhoneDifference in
        let bad = (index == 2 && j == 0) || (index == 8 && symbol == "s")
        let near = (index == 2 && j == 1) || (index == 5 && j == 1)
        return .init(id: j, kind: bad || near ? .substitution : .matched, expected: symbol,
          observed: bad ? "t" : near ? "ɑ" : symbol,
          start: Double(index)*0.44+Double(j)*0.05, end: Double(index)*0.44+Double(j+1)*0.05,
          quality: bad ? .incorrect : near ? .nearCorrect : .correct)
      }
      return .init(target: target, referenceIPA: target.variants[0], phones: phones, supported: true)
    }
    let source = try AcousticDeliveryAnalyzer.track(samples: signal(flat: false))
    let recorded = try AcousticDeliveryAnalyzer.track(samples: signal(flat: true))
    let deliveryWords = targets.map { target in DeliveryWordEvidence(id: target.id, text: target.text,
      source: .init(start: target.sourceStart!, end: target.sourceEnd!),
      take: .init(start: target.sourceStart!, end: target.sourceEnd!), sourceDB: -6, takeDB: -10) }
    let delivery = DeliveryEvidence(source: source, take: recorded, words: deliveryWords,
      boundaries: [.init(id: "thought-it", phrase: "thought‿it", source: .init(start: 0.88, end: 1.76),
        take: .init(start: 0.88, end: 1.76), sourcePause: 0, takePause: 0.24)])
    let evidence = PronunciationEvidence(words: words, duration: 4, recognizedPhones: [],
      qualityPolicy: "DESIGN FIXTURE — not inference", delivery: delivery)
    let sentence = LessonSentence(id: matching.target.segmentRevisionID.uuidString, number: 18,
      text: matching.target.text, translation: "Tôi chưa bao giờ nghĩ rằng nó lại có thể tạo ra khác biệt lớn đến vậy.",
      span: .init(start: 0, end: 4), words: targets.map {
        .init(id: $0.id, text: $0.text, ipaUK: $0.variants[0], ipaUS: $0.variants[0],
          span: .init(start: $0.sourceStart!, end: $0.sourceEnd!))
      })
    let take = PracticeTake(id: matching.takeID.uuidString, lessonID: matching.target.lessonID.uuidString,
      sentenceID: sentence.id, number: 4, createdAt: Date(), duration: 4, outcome: .complete,
      sourceSnapshot: sentence, sourceSpeed: 1, scope: .sentence, wordIDs: [], assessments: [])
    let job = PronunciationJob(id: UUID(), takeID: matching.takeID, target: matching.target,
      words: targets, accent: .uk, provenance: "Design fixture · no model inference", sourceAudioChecksum: "fixture",
      audioChecksum: "fixture", createdAt: Date(), status: .complete, result: evidence)
    return (take, job)
  }
  private static func signal(flat: Bool) -> [Float] {
    var phase = 0.0
    return (0..<64_000).map { index in
      let time = Double(index)/16_000
      let hz = flat ? 150+8*sin(time*5) : 140+35*sin(time*5)
      phase += 2 * .pi * hz/16_000
      let envelope = (flat && time > 1.25 && time < 1.55) ? 0.0 : 0.3+0.12*sin(time*9)
      return Float(envelope*sin(phase))
    }
  }
}
#endif
