import Foundation
import StenoDomain

/// Trennt die Asset-Installation vom Transkriptionslauf.
///
/// Vorher rief `prepareTranscriber` bei jeder Live-Session und jedem
/// Finallauf `ensureAssets` und installierte ungefragt. Damit waere jede
/// Zustimmung, die der Nutzer verweigert, wirkungslos gewesen.
public protocol SpeechAssetGateway: Sendable {
    func isInstalled(locale: Locale) async -> Bool
    func install(locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws
}

public actor SpeechAssetInstaller: ModelInstalling {
    private let assets: any SpeechAssetGateway
    private var activeInstalls: [String: Task<Void, Error>] = [:]

    public init(assets: any SpeechAssetGateway) {
        self.assets = assets
    }

    public nonisolated var bundleDescription: ModelBundleDescription {
        ModelBundleDescription(
            id: .appleSpeech,
            title: "Transcription language",
            source: .appleSystemAssets,
            approximateBytes: SpeechAssetBytes.germanTranscriptionDownload
        )
    }

    public func readiness(for locales: [Locale]) async -> ModelReadiness {
        var installed: Set<Locale> = []
        var missing: [Locale: [String]] = [:]
        for locale in locales {
            if await assets.isInstalled(locale: locale) {
                installed.insert(locale)
            } else {
                // Der Bundletitel, derselbe Name wie in der Liste darueber.
                missing[locale] = [bundleDescription.title]
            }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    public func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        let key = locale.identifier
        if let running = activeInstalls[key] {
            try await running.value
            return
        }
        let task = Task<Void, Error> { [assets] in
            try await assets.install(locale: locale) { fraction in
                progress(ModelInstallProgress(fraction: fraction, title: "Transcription language"))
            }
        }
        activeInstalls[key] = task
        defer { activeInstalls[key] = nil }
        try await task.value
    }

    /// Bricht alle laufenden Installationen ab. Gerufen wird das nur beim
    /// Widerruf der Zustimmung, nicht beim Schliessen des Wizards: eine
    /// erteilte Zustimmung gilt weiter, auch wenn das Fenster zugeht.
    public func cancelInstall() {
        for task in activeInstalls.values {
            task.cancel()
        }
    }
}

/// Gemessene Downloadgroesse eines Apple-Sprachassets, nicht geschaetzt: sie
/// steht im Zustimmungsdialog, und eine erfundene Zahl waere dort eine
/// falsche Zahl vor einer Einwilligung (dieselbe Fehlerklasse wie zuvor bei
/// den Diarisierungsmodellen).
///
/// Gemessen am 2026-08-07 unter macOS 26.5.2 (Build 25F84), aus Apples
/// eigenem Assetkatalog auf dieser Maschine:
/// `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/
/// purpose_auto/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition.xml`,
/// Feld `_DownloadSize` je `AssetSpecifier`:
///   `com.apple.speech.asr.transcription.de`: 142_606_336 Byte (rund 136 MiB)
///   `com.apple.speech.asr.transcription.en`: 138_412_032 Byte (rund 132 MiB)
/// Der Zustimmungsschritt installiert genau eine Sprache; Deutsch ist Stenos
/// Hauptsprache, deshalb steht diese Zahl hier. Apple pflegt diesen Katalog
/// pro macOS-Version selbst - die Zahl ist eine Groessenordnung fuer den
/// Dialog, kein Vertrag, und kann mit einem Systemupdate wandern.
enum SpeechAssetBytes {
    static let germanTranscriptionDownload = 142_606_336
}
