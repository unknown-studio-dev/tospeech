import Foundation

extension PhoneticXeusEvidence {
  /// New helper output must contain complete diagnostics. Historical Codable
  /// values may omit them; history is read directly and is never re-converted.
  func validateReferenceDiagnostics() throws {
    func require(_ condition: Bool) throws {
      if !condition { throw PhoneticXeusError.invalidEvidence }
    }
    func probability(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
    func hypothesis(_ value: XeusPhoneDiagnostic.Hypothesis) throws {
      try require(["correct", "likelyIncorrect", "uncertain", "unavailable"].contains(value.status))
      try require(value.expectedProbability.map(probability) ?? true)
      try require(value.expectedTokenProbability.map(probability) ?? true)
      try require(value.logMargin.map(\.isFinite) ?? true)
    }
    func region(_ value: XeusReferenceDiagnostics.Region?, frames: Int, duration: Double) throws {
      guard let value else { return }
      try require(value.startFrame >= 0 && value.endFrame > value.startFrame && value.endFrame <= frames)
      try require(value.start.isFinite && value.end.isFinite && value.start >= 0 && value.end <= duration && value.end > value.start)
      try require(abs(value.start - Double(value.startFrame)*0.02) < 0.0001)
      try require(abs(value.end - min(duration, Double(value.endFrame)*0.02)) < 0.0001)
      try require((0...(value.endFrame-value.startFrame)).contains(value.speechFrames) && probability(value.blankMean))
      var previous = value.startFrame
      for token in value.tokens {
        try require(!token.symbol.isEmpty && token.startFrame >= previous && token.endFrame > token.startFrame && token.endFrame <= value.endFrame && probability(token.posterior))
        previous = token.endFrame
      }
      try require(value.topCandidates.count <= 3 && value.topCandidates.allSatisfy { !$0.symbol.isEmpty && probability($0.posterior) })
    }
    guard let reference, let sourceRecognizedPhones else { throw PhoneticXeusError.invalidEvidence }
    try require([XeusReferenceDiagnostics.policy, XeusReferenceDiagnostics.policyV2].contains(reference.policy))
    try require(Set(reference.groups.map(\.id)).count == reference.groups.count)
    let expected = words.flatMap { word in word.phones.enumerated().map { index, phone in
      XeusReferenceDiagnostics.Member(wordID: word.id, phoneIndex: index, displayPhone: phone.expected)
    } }
    let members = reference.groups.flatMap(\.members)
    try require(members.count == expected.count && Set(members) == Set(expected))
    let groups = Dictionary(uniqueKeysWithValues: reference.groups.map { ($0.id, $0) })
    for group in reference.groups {
      try require(!group.members.isEmpty && group.shared == (group.members.count > 1))
      try region(group.source, frames: sourceShape[0], duration: sourceDuration)
      try region(group.take, frames: takeShape[0], duration: duration)
      let comparison = group.comparison
      if let distance = comparison.jsDistance {
        try require(probability(distance) && comparison.state == "UNCALIBRATED")
        guard let source = group.source, let take = group.take else { throw PhoneticXeusError.invalidEvidence }
        try require(source.speechFrames > 0 && take.speechFrames > 0)
        try require(comparison.pathSteps >= max(source.speechFrames, take.speechFrames)
          && comparison.pathSteps <= source.speechFrames + take.speechFrames - 1)
      } else {
        try require(comparison.state == "INSUFFICIENT_EVIDENCE" && comparison.pathSteps == 0)
      }
      try require(comparison.sequenceEditDistance.map { $0 >= 0 && $0 <= max(group.source?.tokens.count ?? 0, group.take?.tokens.count ?? 0) } ?? (group.source == nil || group.take == nil))
    }
    let states = ["SUPPORTED", "SUPPORTED_BY_REFERENCE_CLASS", "SUPPORTED_BY_CONTRAST_HEAD",
      "LIKELY_PRONUNCIATION_DIFFERENCE", "LIKELY_PRONUNCIATION_DIFFERENCE_BY_HEAD", "REFERENCE_UNMAPPED",
      "REFERENCE_WEAK", "MODEL_CANNOT_DISTINGUISH", "MODEL_REPRESENTATION_MISMATCH", "ALIGNMENT_UNCERTAIN",
      "INSUFFICIENT_EVIDENCE"]
    for word in words {
      for (index, phone) in word.phones.enumerated() {
        guard let detail = phone.diagnostic, let group = groups[detail.groupID] else { throw PhoneticXeusError.invalidEvidence }
        try require(group.members.contains(.init(wordID: word.id, phoneIndex: index, displayPhone: phone.expected)))
        try require(states.contains(detail.state))
        if reference.policy == XeusReferenceDiagnostics.policyV2 {
          try require(detail.licence.map(PhoneticXeusAdapter.licences.contains) ?? false)
          try require(detail.licence == phone.licence)
          try require(detail.unitID != nil)
        }
        try require(detail.lengthStatus == (phone.expected.contains("ː") ? "UNVERIFIED" : "NOT_SEPARATELY_ASSESSED"))
        try hypothesis(detail.sourceHypothesis); try hypothesis(detail.takeHypothesis)
        try require(detail.sourceHypothesis.status == phone.sourceStatus)
        // A PAIRS unit is one licensed sound shown as two phones: shared evidence there
        // is not an alignment failure. Only members spanning several units stay ungraded.
        if group.shared || group.takeBoundaryShared == true {
          let units = Set(group.members.compactMap { member in words.first { $0.id == member.wordID }?.phones[member.phoneIndex].unitID ?? "\(member.wordID)#\(member.phoneIndex)" })
          if units.count > 1 || group.takeBoundaryShared == true { try require(["ALIGNMENT_UNCERTAIN", "INSUFFICIENT_EVIDENCE"].contains(detail.state)) }
        }
      }
    }
    for (tokens, duration) in [(sourceRecognizedPhones, sourceDuration), (recognizedPhones, self.duration)] {
      var previous = 0.0
      for token in tokens {
        try require(!token.symbol.isEmpty && token.start.isFinite && token.end.isFinite && token.start >= previous && token.end > token.start && token.end <= duration && probability(token.posterior))
        previous = token.end
      }
    }
  }
}
