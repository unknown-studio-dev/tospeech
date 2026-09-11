import Foundation
import Testing

@testable import EchoLab

struct WhisperModelCatalogTests {
  @Test func hasFourVariantsWithSmallDefault() {
    #expect(WhisperModelCatalog.all.count == 4)
    #expect(WhisperModelVariant.allCases == [.tiny, .base, .small, .large])
    #expect(WhisperModelVariant.default == .small)
  }

  @Test func eachVariantMapsToAWhisperKitModelName() {
    #expect(WhisperModelVariant.tiny.whisperKitModel == "tiny.en")
    #expect(WhisperModelVariant.base.whisperKitModel == "base.en")
    #expect(WhisperModelVariant.small.whisperKitModel == "small.en")
    #expect(WhisperModelVariant.large.whisperKitModel == "large-v3")
  }

  @Test func variantsCarryDistinctNonEmptyMetadata() {
    for variant in WhisperModelCatalog.all {
      #expect(!variant.displayName.isEmpty)
      #expect(variant.approximateDownloadBytes > 0)
    }
    let sizes = WhisperModelCatalog.all.map(\.approximateDownloadBytes)
    #expect(sizes == sizes.sorted())
    #expect(WhisperModelCatalog.engineKey == "whisper-transcription")
  }
}
