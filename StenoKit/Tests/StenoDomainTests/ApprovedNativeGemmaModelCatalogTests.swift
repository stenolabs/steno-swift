import Testing
@testable import StenoDomain

@Suite("Approved native Gemma model catalog")
struct ApprovedNativeGemmaModelCatalogTests {
    @Test("production pins the reviewed Gemma 4 E2B checkpoint")
    func productionPinIsExact() throws {
        let pin = try #require(ApprovedNativeGemmaModelCatalog.productionPin)

        #expect(pin.modelIdentifier == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(pin.checkpointRevision == "238767527555cb75a05732a84dff5d6ba0dd6809")
        #expect(pin.adapterRevision == "37688d2cf7d3906e08c74479c9d9949ce6b81136")
        #expect(pin.licenseIdentifier == "gemma")
        #expect(pin.manifestSHA256 == "dab4d380ff03b1e6ac34fa47a0db672e540ee399b9d04dc765ba832a6f59cca5")
        #expect(ApprovedNativeGemmaModelCatalog.production.contains(pin))
    }
}
