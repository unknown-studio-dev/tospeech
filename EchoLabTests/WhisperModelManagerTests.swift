import Foundation
import Testing

@testable import EchoLab

struct WhisperModelManagerTests {
  private func release(_ version: String, _ status: String) -> EngineReleaseRecord {
    EngineReleaseRecord(
      id: UUID(), engineKey: WhisperModelCatalog.engineKey, version: version, status: status,
      relativePath: nil)
  }

  @Test func alwaysListsFourVariantsInCatalogOrder() {
    let states = TranscriptionModelStates.make(releases: [], active: nil)
    #expect(states.map(\.variant) == [.tiny, .base, .small, .large])
    #expect(states.allSatisfy { $0.status == "not_installed" })
    #expect(states.allSatisfy { !$0.isActive })
  }

  @Test func mapsStatusAndMarksActive() {
    let releases = [release("small.en", "installed"), release("tiny.en", "downloading")]
    let states = TranscriptionModelStates.make(releases: releases, active: "small")
    let byVariant = Dictionary(uniqueKeysWithValues: states.map { ($0.variant, $0) })
    #expect(byVariant[.small]?.status == "installed")
    #expect(byVariant[.small]?.isActive == true)
    #expect(byVariant[.tiny]?.status == "downloading")
    #expect(byVariant[.tiny]?.isActive == false)
    #expect(byVariant[.base]?.status == "not_installed")
    #expect(byVariant[.large]?.status == "not_installed")
  }
}
