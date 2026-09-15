import Foundation

enum PronunciationComparison {
  private struct Choice { let previous: Int; let ipa: String; let phones: [String] }

  static func compare(targets: [PronunciationWordTarget], heard: [RecognizedPhone], duration: Double) throws -> PronunciationEvidence {
    guard targets.count <= 128, heard.count <= 512 else { throw ContentMatchingError.tooLong }
    let variants = targets.map { word in word.variants.compactMap { ipa -> (String, [String])? in
      PhoneInventory.parse(ipa).map { (ipa, $0) }
    } }
    // Without a pronunciation for every word, sequence alignment cannot safely
    // assign neighboring emissions to words. Retain raw recognition, no diagnoses.
    guard !heard.isEmpty, !targets.isEmpty, variants.allSatisfy({ !$0.isEmpty }) else {
      return PronunciationEvidence(words: targets.map {
        WordPronunciationEvidence(target: $0, referenceIPA: $0.variants.first, phones: [], supported: false)
      }, duration: duration, recognizedPhones: heard)
    }
    let n = heard.count
    var costs = Array(repeating: Double.infinity, count: n + 1)
    costs[0] = 0
    var paths: [[Choice?]] = []
    for alternatives in variants {
      var next = Array(repeating: Double.infinity, count: n + 1)
      var choices = Array<Choice?>(repeating: nil, count: n + 1)
      for start in 0...n where costs[start].isFinite {
        for (ipa, expected) in alternatives {
          let limit = min(n - start, expected.count + 5)
          // One edit matrix produces the costs for every possible end boundary.
          var row = (0...limit).map(Double.init)
          for (i, phone) in expected.enumerated() {
            var newer = Array(repeating: 0.0, count: limit + 1)
            newer[0] = Double(i + 1)
            if limit > 0 {
              for j in 1...limit {
                let same = PhoneInventory.canonical(phone) == PhoneInventory.canonical(heard[start+j-1].symbol)
                newer[j] = min(row[j] + 1, newer[j-1] + 1, row[j-1] + (same ? -0.01 : 1))
              }
            }
            row = newer
          }
          for length in 0...limit {
            let value = costs[start] + row[length]
            if value < next[start+length] {
              next[start+length] = value
              choices[start+length] = Choice(previous: start, ipa: ipa, phones: expected)
            }
          }
        }
      }
      costs = next
      paths.append(choices)
    }
    guard costs[n].isFinite else { throw ContentMatchingError.tooLong }
    var end = n
    var words: [WordPronunciationEvidence] = []
    for index in targets.indices.reversed() {
      guard let choice = paths[index][end] else { throw ContentMatchingError.tooLong }
      words.append(WordPronunciationEvidence(target: targets[index], referenceIPA: choice.ipa,
        phones: align(choice.phones, Array(heard[choice.previous..<end])), supported: true))
      end = choice.previous
    }
    return PronunciationEvidence(words: words.reversed(), duration: duration, recognizedPhones: heard)
  }

  static func gate(_ learner: PronunciationEvidence, reference: PronunciationEvidence) -> PronunciationEvidence {
    let referenceByID = Dictionary(uniqueKeysWithValues: reference.words.map { ($0.id, $0) })
    let words = learner.words.map { word -> WordPronunciationEvidence in
      guard let source = referenceByID[word.id], source.supported, source.observations.isEmpty else {
        return WordPronunciationEvidence(target: word.target, referenceIPA: word.referenceIPA,
          phones: word.phones.map { phone in
            PhoneDifference(id: phone.id, kind: .referenceUncertain,
              expected: phone.expected, observed: phone.observed, start: phone.start, end: phone.end)
          }, supported: word.supported)
      }
      return word
    }
    return PronunciationEvidence(words: words, duration: learner.duration,
      recognizedPhones: learner.recognizedPhones, referencePhones: reference.recognizedPhones,
      qualityPolicy: PronunciationQualityPolicy.version)
  }

  private static func align(_ expected: [String], _ heard: [RecognizedPhone]) -> [PhoneDifference] {
    let m = expected.count, n = heard.count
    var d = Array(repeating: Array(repeating: 0.0, count: n+1), count: m+1)
    for i in 0...m { d[i][0] = Double(i) }
    for j in 0...n { d[0][j] = Double(j) }
    func same(_ i: Int, _ j: Int) -> Bool {
      PhoneInventory.canonical(expected[i]) == PhoneInventory.canonical(heard[j].symbol)
    }
    if m > 0 && n > 0 {
      for i in 1...m { for j in 1...n {
        d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1] + (same(i-1,j-1) ? -0.01 : 1))
      } }
    }
    var i = m, j = n
    var output: [(PhoneDifference.Kind, String?, RecognizedPhone?)] = []
    while i > 0 || j > 0 {
      if i > 0 && j > 0 && abs(d[i][j] - (d[i-1][j-1] + (same(i-1,j-1) ? -0.01 : 1))) < 1e-6 {
        let kind: PhoneDifference.Kind = heard[j-1].posterior < 0.6 || heard[j-1].symbol == "?"
          ? .uncertain : (same(i-1,j-1) ? .matched : .substitution)
        output.append((kind, expected[i-1], heard[j-1])); i -= 1; j -= 1
      } else if i > 0 && abs(d[i][j] - d[i-1][j] - 1) < 1e-6 {
        output.append((.omission, expected[i-1], nil)); i -= 1
      } else {
        output.append((heard[j-1].posterior < 0.6 ? .uncertain : .insertion, nil, heard[j-1])); j -= 1
      }
    }
    return output.reversed().enumerated().map { index, value in
      var phone = PhoneDifference(id: index, kind: value.0, expected: value.1, observed: value.2?.symbol,
        start: value.2?.start, end: value.2?.end)
      phone.quality = PronunciationQualityPolicy.quality(for: phone)
      return phone
    }
  }
}
