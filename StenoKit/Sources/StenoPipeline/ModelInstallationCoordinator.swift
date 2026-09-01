import Darwin
import Foundation
import StenoDiarization
import StenoDomain
import StenoTranscription

public enum ModelInstallationError: Error, Equatable, LocalizedError, Sendable {
    case consentMissing
    case nativeGemmaPinNotApproved
    case nativeGemmaSourceInvalid
    case nativeGemmaConfirmationInvalid
    case nativeGemmaImportInProgress
    case nativeGemmaCancellationInProgress
    case nativeGemmaSnapshotMismatch

    public var errorDescription: String? {
        switch self {
        case .consentMissing:
            "Steno may not download its models yet. Allow it in Settings under Models."
        case .nativeGemmaPinNotApproved:
            "This native Gemma model is not approved for import."
        case .nativeGemmaSourceInvalid:
            "The approved native Gemma source is no longer the same directory."
        case .nativeGemmaConfirmationInvalid:
            "This native Gemma import confirmation is no longer valid."
        case .nativeGemmaImportInProgress:
            "A native Gemma import is already in progress."
        case .nativeGemmaCancellationInProgress:
            "Native Gemma imports are unavailable while model installation is being cancelled."
        case .nativeGemmaSnapshotMismatch:
            "The native Gemma importer returned model provenance that was not approved."
        }
    }
}

/// A single-use capability minted only by `ModelInstallationCoordinator`.
///
/// It deliberately carries neither a source URL nor a model pin in its public
/// API. Possession alone is insufficient because the coordinator revalidates
/// the stored pin and directory identity immediately before it starts import.
public struct NativeGemmaModelImportConfirmation: Sendable {
    fileprivate let nonce: UUID

    fileprivate init(nonce: UUID) {
        self.nonce = nonce
    }
}

/// Fasst die Installer zusammen und beantwortet, ob Steno fuer eine Sprache
/// arbeitsfaehig ist. Die Zustimmung wird hineingereicht, nicht gelesen:
/// StenoKit kennt UserDefaults nicht.
public actor ModelInstallationCoordinator {
    private let installers: [any ModelInstalling]
    private let nativeGemmaCatalog: ApprovedNativeGemmaModelCatalog
    private var isCancelled = false
    private var nativeGemmaCancellationCount = 0
    private var nativeGemmaConfirmation: PendingNativeGemmaImport?
    private var nativeGemmaImport: InFlightNativeGemmaImport?

    public init(installers: [any ModelInstalling]) {
        self.installers = installers
        nativeGemmaCatalog = .production
    }

    package init(
        installers: [any ModelInstalling],
        nativeGemmaCatalog: ApprovedNativeGemmaModelCatalog
    ) {
        self.installers = installers
        self.nativeGemmaCatalog = nativeGemmaCatalog
    }

    /// Die Aufstellung, mit der die App laeuft. Sie steht hier und nicht in
    /// der App-Schicht, weil nur StenoPipeline beide Installer sieht: die App
    /// bindet StenoDiarization nicht ein.
    public static func standard(
        modelCacheDirectory: URL? = nil,
        speechAssets: any SpeechAssetGateway = SystemSpeechAssets()
    ) throws -> ModelInstallationCoordinator {
        ModelInstallationCoordinator(installers: [
            SpeechAssetInstaller(assets: speechAssets),
            DiarizationModelInstaller(
                modelCacheDirectory: modelCacheDirectory,
                manifest: try ModelChecksumManifest.bundled()
            ),
            ParakeetModelInstaller(
                modelCacheDirectory: modelCacheDirectory,
                manifest: try ParakeetModelInstaller.bundledManifest()
            ),
        ])
    }

    /// Titel, Quelle und Groesse jedes Bundles, ohne den Aktor zu betreten:
    /// die Einstellungen zeigen das, bevor irgendetwas geladen wurde.
    public nonisolated var bundleDescriptions: [ModelBundleDescription] {
        installers.map(\.bundleDescription)
    }

    public func readiness(for locales: [Locale]) async -> ModelReadiness {
        await readiness(
            for: locales,
            bundleIDs: Set(installers.map { $0.bundleDescription.id })
        )
    }

    public func readiness(
        for locales: [Locale],
        bundleIDs: Set<ModelBundleID>
    ) async -> ModelReadiness {
        var installed = Set(locales)
        var missing: [Locale: [String]] = [:]
        for installer in installers where bundleIDs.contains(installer.bundleDescription.id) {
            let readiness = await installer.readiness(for: locales)
            for locale in locales where !readiness.isReady(for: locale) {
                installed.remove(locale)
                missing[locale, default: []].append(contentsOf: readiness.missingNames(for: locale))
            }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    public func installAll(
        for locale: Locale,
        consentGranted: Bool,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        try await install(
            bundleIDs: Set(installers.map { $0.bundleDescription.id }),
            for: locale,
            consentGranted: consentGranted,
            progress: progress
        )
    }

    public func install(
        bundleIDs: Set<ModelBundleID>,
        for locale: Locale,
        consentGranted: Bool,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        guard consentGranted else { throw ModelInstallationError.consentMissing }
        isCancelled = false
        for installer in installers where bundleIDs.contains(installer.bundleDescription.id) {
            // Ein Widerruf in der Luecke zwischen zwei Installern erwischt
            // keinen laufenden Task, den man abbrechen koennte. Ohne diese
            // Pruefung fiele der naechste Download trotzdem an - "es wird
            // nichts mehr geladen" waere dann nur die halbe Wahrheit.
            guard !isCancelled else { throw CancellationError() }
            try await installer.install(for: locale, progress: progress)
        }
    }

    /// Mints a one-shot import capability only after the existing model
    /// consent has been supplied, the pin is in the fixed catalogue, and the
    /// selected directory has been opened without following a symlink.
    ///
    /// No importer or destination store is touched here. This is deliberately
    /// the earliest narrow chokepoint for native model import consent.
    public func mintNativeGemmaImportConfirmation(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        consentGranted: Bool
    ) throws -> NativeGemmaModelImportConfirmation {
        guard consentGranted else { throw ModelInstallationError.consentMissing }
        guard nativeGemmaCancellationCount == 0 else {
            throw ModelInstallationError.nativeGemmaCancellationInProgress
        }
        guard nativeGemmaCatalog.contains(pin) else {
            throw ModelInstallationError.nativeGemmaPinNotApproved
        }
        let sourceIdentity = try Self.sourceIdentity(for: sourceRoot)
        let nonce = UUID()
        nativeGemmaConfirmation = PendingNativeGemmaImport(
            nonce: nonce,
            pin: pin,
            sourceRoot: sourceRoot,
            sourceIdentity: sourceIdentity
        )
        return NativeGemmaModelImportConfirmation(nonce: nonce)
    }

    /// Consumes the confirmation before it forwards anything to the importer.
    /// A failed or cancelled attempt is therefore never replayable.
    public func importNativeGemmaModel(
        using confirmation: NativeGemmaModelImportConfirmation,
        importer: any NativeGemmaModelImporting
    ) async throws -> NativeGemmaModelSnapshot {
        guard nativeGemmaCancellationCount == 0 else {
            throw ModelInstallationError.nativeGemmaCancellationInProgress
        }
        guard nativeGemmaImport == nil else {
            throw ModelInstallationError.nativeGemmaImportInProgress
        }
        guard let pending = nativeGemmaConfirmation,
              pending.nonce == confirmation.nonce
        else {
            throw ModelInstallationError.nativeGemmaConfirmationInvalid
        }
        nativeGemmaConfirmation = nil
        guard nativeGemmaCatalog.contains(pending.pin) else {
            throw ModelInstallationError.nativeGemmaPinNotApproved
        }
        guard try Self.sourceIdentity(for: pending.sourceRoot) == pending.sourceIdentity else {
            throw ModelInstallationError.nativeGemmaSourceInvalid
        }

        let importID = UUID()
        let task = Task<NativeGemmaModelSnapshot, Error> {
            try await importer.importApprovedNativeGemmaModel(
                pin: pending.pin,
                sourceRoot: pending.sourceRoot,
                sourceIdentity: pending.sourceIdentity
            )
        }
        nativeGemmaImport = InFlightNativeGemmaImport(
            id: importID,
            task: task
        )

        return try await withTaskCancellationHandler {
            do {
                let snapshot = try await task.value
                clearNativeGemmaImport(id: importID)
                guard snapshot == pending.pin.snapshot else {
                    throw ModelInstallationError.nativeGemmaSnapshotMismatch
                }
                return snapshot
            } catch {
                clearNativeGemmaImport(id: importID)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Widerruf oder geschlossenes Fenster: nichts Laufendes weiterladen und
    /// nichts Weiteres anfangen.
    public func cancelAll() async {
        nativeGemmaCancellationCount += 1
        defer { nativeGemmaCancellationCount -= 1 }
        isCancelled = true
        nativeGemmaConfirmation = nil
        let nativeGemmaImport = nativeGemmaImport
        nativeGemmaImport?.task.cancel()
        for installer in installers {
            await installer.cancelInstall()
        }
        if let nativeGemmaImport {
            _ = await nativeGemmaImport.task.result
            clearNativeGemmaImport(id: nativeGemmaImport.id)
        }
    }

    private func clearNativeGemmaImport(id: UUID) {
        guard nativeGemmaImport?.id == id else { return }
        nativeGemmaImport = nil
    }

    private static func sourceIdentity(for sourceRoot: URL) throws -> NativeGemmaSourceIdentity {
        let descriptor = sourceRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ModelInstallationError.nativeGemmaSourceInvalid }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw ModelInstallationError.nativeGemmaSourceInvalid
        }
        return NativeGemmaSourceIdentity(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}

private struct PendingNativeGemmaImport: Sendable {
    let nonce: UUID
    let pin: ApprovedNativeGemmaModelPin
    let sourceRoot: URL
    let sourceIdentity: NativeGemmaSourceIdentity
}

private struct InFlightNativeGemmaImport: Sendable {
    let id: UUID
    let task: Task<NativeGemmaModelSnapshot, Error>
}
