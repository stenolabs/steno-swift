#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaModelStore)
import Foundation
import StenoDomain
import StenoGemmaIPC
@_spi(StenoApp) import StenoGemmaModelStore
import StenoGemmaProcessGate
import StenoPipeline

enum NativeGemmaModelStoreAdapterError: Error, Equatable, Sendable {
    case adapterRevisionMismatch(expected: String, actual: String)
    case modelNotApproved
    case provenanceMismatch
}

/// Bridges the consent-owning StenoKit coordinator to the consent-agnostic local store.
///
/// The adapter does not select models, discover checkpoints, download files, or activate MLX.
/// It receives only the pin and source identity already consumed by the coordinator.
struct NativeGemmaModelStoreAdapter: NativeGemmaModelImporting, Sendable {
    private let importer: NativeGemmaModelImporter

    init(importer: NativeGemmaModelImporter? = nil) {
        self.importer = importer ?? NativeGemmaModelImporter(
            configuration: .production(
                processGateConfigurationProvider: GemmaProcessGateConfiguration.production
            )
        )
    }

    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) async throws -> NativeGemmaModelSnapshot {
        let requirements = try Self.requirements(for: pin)
        let verified = try await importer.importModel(
            from: sourceRoot,
            expectedSourceIdentity: GemmaModelSourceIdentity(
                deviceID: sourceIdentity.deviceID,
                inode: sourceIdentity.inode
            ),
            requirements: requirements
        )
        let snapshot = NativeGemmaModelSnapshot(
            modelIdentifier: verified.modelIdentifier,
            checkpointRevision: verified.checkpointRevision,
            adapterRevision: verified.adapterRevision,
            licenseIdentifier: verified.licenseIdentifier,
            manifestSHA256: verified.manifestSHA256
        )
        guard snapshot.isWellFormed, snapshot == pin.snapshot else {
            throw NativeGemmaModelStoreAdapterError.provenanceMismatch
        }
        return snapshot
    }

    static func requirements(for pin: ApprovedNativeGemmaModelPin) throws -> GemmaModelRequirements {
        guard pin.adapterRevision == GemmaIPCBuildInfo.adapterRevision else {
            throw NativeGemmaModelStoreAdapterError.adapterRevisionMismatch(
                expected: GemmaIPCBuildInfo.adapterRevision,
                actual: pin.adapterRevision
            )
        }
        return try GemmaModelRequirements(
            modelIdentifier: pin.modelIdentifier,
            checkpointRevision: pin.checkpointRevision,
            adapterRevision: pin.adapterRevision,
            licenseIdentifier: pin.licenseIdentifier,
            expectedManifestSHA256: pin.manifestSHA256
        )
    }

    /// Resolves only an exact app-approved snapshot from Steno's immutable store.
    ///
    /// This is the app side of the double allowlist. The helper independently requires the same
    /// exact pin in its activation catalog before it materializes MLX.
    static func productionInstalledModelDirectory(
        for model: GemmaModelSnapshotPin
    ) throws -> VerifiedGemmaModelDirectory {
        let configuration = NativeGemmaModelStoreConfiguration.production(
            processGateConfigurationProvider: GemmaProcessGateConfiguration.production
        )
        return try resolveInstalledModelDirectory(
            for: model,
            resolver: NativeGemmaInstalledModelResolver(configuration: configuration),
            isApproved: ApprovedNativeGemmaModelCatalog.production.contains
        )
    }

    static func resolveInstalledModelDirectory(
        for model: GemmaModelSnapshotPin,
        resolver: NativeGemmaInstalledModelResolver,
        isApproved: (ApprovedNativeGemmaModelPin) -> Bool
    ) throws -> VerifiedGemmaModelDirectory {
        let approvedPin = try ApprovedNativeGemmaModelPin(
            modelIdentifier: model.modelIdentifier,
            checkpointRevision: model.checkpointRevision,
            adapterRevision: model.adapterRevision,
            licenseIdentifier: model.licenseIdentifier,
            manifestSHA256: model.manifestSHA256
        )
        guard isApproved(approvedPin) else {
            throw NativeGemmaModelStoreAdapterError.modelNotApproved
        }
        return try resolver.resolve(requirements: requirements(for: approvedPin))
    }
}

/// The sole app-level entry point for an explicitly approved native Gemma import.
///
/// The safety coordinator reserves import admission before consent is consumed or the store is
/// touched. Recording intent can therefore reject a new import or cancel and drain the exact
/// admitted task before microphone permission and capture begin.
struct NativeGemmaModelImportFacade: Sendable {
    private let installationCoordinator: ModelInstallationCoordinator
    private let safetyCoordinator: any NativeGemmaCoordinator
    private let importer: any NativeGemmaModelImporting

    init(
        installationCoordinator: ModelInstallationCoordinator,
        safetyCoordinator: any NativeGemmaCoordinator = NativeGemmaRecordingBarrierFactory.live(),
        importer: any NativeGemmaModelImporting = NativeGemmaModelStoreAdapter()
    ) {
        self.installationCoordinator = installationCoordinator
        self.safetyCoordinator = safetyCoordinator
        self.importer = importer
    }

    func importModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        consentGranted: Bool
    ) async throws -> NativeGemmaModelSnapshot {
        try await safetyCoordinator.performModelImport {
            let confirmation = try await installationCoordinator
                .mintNativeGemmaImportConfirmation(
                    pin: pin,
                    sourceRoot: sourceRoot,
                    consentGranted: consentGranted
                )
            return try await installationCoordinator.importNativeGemmaModel(
                using: confirmation,
                importer: importer
            )
        }
    }
}
#endif
