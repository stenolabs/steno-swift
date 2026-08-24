import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Transcription model catalog")
struct TranscriptionModelCatalogTests {
    @Test("Apple is the production default for both uses")
    func appleDefaults() {
        let catalog = TranscriptionModelCatalog.standard

        #expect(catalog.defaultProvider(for: .live) == .apple)
        #expect(catalog.defaultProvider(for: .final) == .apple)
        #expect(catalog.descriptor(for: .apple)?.maturity == .production)
    }

    @Test("Parakeet final is selectable but live needs the experimental gate")
    func parakeetCapabilities() {
        let catalog = TranscriptionModelCatalog.standard
        let german = Locale(identifier: "de-DE")

        #expect(
            catalog.supports(
                .parakeetTDTv3,
                use: .final,
                locale: german,
                experimentalLiveEnabled: false
            )
        )
        #expect(
            !catalog.supports(
                .parakeetTDTv3,
                use: .live,
                locale: german,
                experimentalLiveEnabled: false
            )
        )
        #expect(
            catalog.supports(
                .parakeetTDTv3,
                use: .live,
                locale: german,
                experimentalLiveEnabled: true
            )
        )
    }

    @Test("Parakeet rejects languages outside its exact catalog")
    func unsupportedLanguage() {
        let catalog = TranscriptionModelCatalog.standard

        #expect(
            !catalog.supports(
                .parakeetTDTv3,
                use: .final,
                locale: Locale(identifier: "ja-JP"),
                experimentalLiveEnabled: true
            )
        )
    }
}
