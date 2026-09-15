import Foundation
import Testing
@testable import ToSpeech

struct CTCAlignmentTests {
  private func emissions(_ path: [Int], width: Int = 4) -> [[Float]] {
    path.map { label in (0..<width).map { $0 == label ? Float(-0.01) : Float(-20) } }
  }

  @Test func silenceRepeatedCharactersAndEndAreAligned() throws {
    let result = try CTCAlignment.align(logProbabilities: emissions([0,1,1,0,1,2,2,0]), labels: [1,1,2])
    #expect(result == [.init(start: 1, end: 3), .init(start: 4, end: 5), .init(start: 5, end: 7)])
  }

  @Test func rejectsImpossibleMalformedAndUnboundedInputs() throws {
    #expect(try CTCAlignment.align(logProbabilities: emissions([1,1]), labels: [1,1]) == nil)
    #expect(try CTCAlignment.align(logProbabilities: [[.nan, 0]], labels: [1]) == nil)
    #expect(try CTCAlignment.align(logProbabilities: [[0, 1], [0]], labels: [1]) == nil)
    #expect(try CTCAlignment.align(logProbabilities: emissions([1,2]), labels: [9]) == nil)
    #expect(try CTCAlignment.align(logProbabilities: emissions(Array(repeating: 0, count: 1601)), labels: [1]) == nil)
  }

  @Test func cancellationStopsDynamicProgramming() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try CTCAlignment.align(logProbabilities: emissions([1,2]), labels: [1,2])
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError {}
    catch { Issue.record("Unexpected error: \(error)") }
  }
}
