import Testing
import Foundation
@testable import StenoDomain

@Suite("Model readiness")
struct ModelInstallingTests {
    @Test("readiness is answered per locale, not globally")
    func readinessIsPerLocale() {
        let readiness = ModelReadiness(
            installed: [Locale(identifier: "de-DE")],
            missing: [Locale(identifier: "en-US"): ["Parakeet_de"]]
        )
        #expect(readiness.isReady(for: Locale(identifier: "de-DE")))
        #expect(!readiness.isReady(for: Locale(identifier: "en-US")))
    }

    @Test("a bundle description names its source and stays free of technical jargon")
    func descriptionNamesSource() {
        let description = ModelBundleDescription(
            title: "Speaker separation",
            source: .huggingFace,
            approximateBytes: 92_000_000
        )
        #expect(description.source.displayHost == "huggingface.co")
    }
}
