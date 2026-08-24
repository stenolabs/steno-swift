import Foundation
import StenoDiarization
import StenoDomain
import StenoTranscription

public enum ModelInstallationError: Error, Equatable, LocalizedError, Sendable {
    case consentMissing

    public var errorDescription: String? {
        switch self {
        case .consentMissing:
            "Steno may not download its models yet. Allow it in Settings under Models."
        }
    }
}

/// Fasst die Installer zusammen und beantwortet, ob Steno fuer eine Sprache
/// arbeitsfaehig ist. Die Zustimmung wird hineingereicht, nicht gelesen:
/// StenoKit kennt UserDefaults nicht.
public actor ModelInstallationCoordinator {
    private let installers: [any ModelInstalling]
    private var isCancelled = false

    public init(installers: [any ModelInstalling]) {
        self.installers = installers
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

    /// Widerruf oder geschlossenes Fenster: nichts Laufendes weiterladen und
    /// nichts Weiteres anfangen.
    public func cancelAll() async {
        isCancelled = true
        for installer in installers {
            await installer.cancelInstall()
        }
    }
}
