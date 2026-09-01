#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaModelStore)
import StenoDomain
import StenoGemmaIPC
import Testing
@testable import steno_macos

@Suite("Native Gemma model-store adapter")
struct NativeGemmaModelStoreAdapterTests {
    @Test("only the adapter revision compiled into IPC can be imported")
    func adapterRevisionIsPinnedToTheBuild() throws {
        let matching = try pin(adapterRevision: GemmaIPCBuildInfo.adapterRevision)
        let requirements = try NativeGemmaModelStoreAdapter.requirements(for: matching)
        #expect(requirements.adapterRevision == GemmaIPCBuildInfo.adapterRevision)

        let mismatched = try pin(adapterRevision: String(repeating: "d", count: 40))
        #expect(throws: NativeGemmaModelStoreAdapterError.adapterRevisionMismatch(
            expected: GemmaIPCBuildInfo.adapterRevision,
            actual: String(repeating: "d", count: 40)
        )) {
            _ = try NativeGemmaModelStoreAdapter.requirements(for: mismatched)
        }
    }

    @Test("the empty production catalog rejects activation before store resolution")
    func productionCatalogRejectsUnapprovedActivation() throws {
        let approvedPin = try pin(adapterRevision: GemmaIPCBuildInfo.adapterRevision)
        let model = try GemmaModelSnapshotPin(
            modelIdentifier: approvedPin.modelIdentifier,
            checkpointRevision: approvedPin.checkpointRevision,
            adapterRevision: approvedPin.adapterRevision,
            licenseIdentifier: approvedPin.licenseIdentifier,
            manifestSHA256: approvedPin.manifestSHA256
        )

        #expect(throws: NativeGemmaModelStoreAdapterError.modelNotApproved) {
            _ = try NativeGemmaModelStoreAdapter
                .productionInstalledModelDirectory(for: model)
        }
    }

    private func pin(adapterRevision: String) throws -> ApprovedNativeGemmaModelPin {
        try ApprovedNativeGemmaModelPin(
            modelIdentifier: "google/gemma-4-test",
            checkpointRevision: String(repeating: "a", count: 40),
            adapterRevision: adapterRevision,
            licenseIdentifier: "Gemma-Terms",
            manifestSHA256: String(repeating: "c", count: 64)
        )
    }
}
#endif
