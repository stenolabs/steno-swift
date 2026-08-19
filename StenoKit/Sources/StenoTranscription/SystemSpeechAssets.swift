import Foundation
import Speech
import StenoDomain

/// Der produktive Zugang zu Apples Assetkatalog.
///
/// Aufgabe 5 hat `SpeechAssetGateway` eingefuehrt, aber nur einen
/// Testdoppelgaenger dafuer. Ohne einen echten Erfueller haette die App gar
/// keinen Sprachassetinstaller bauen koennen, und der Knopf in den
/// Einstellungen haette nur die Diarisierung bedient.
///
/// Die Installationslogik selbst wird nicht verdoppelt: Reservierung,
/// Fortschritt und das Warten auf eine fremde, schon laufende Installation
/// liegen weiter in `SpeechAnalyzerProvider`, wo sie ueber Monate
/// zurechtgerueckt wurden.
public struct SystemSpeechAssets: SpeechAssetGateway {
    public init() {}

    public func isInstalled(locale: Locale) async -> Bool {
        guard let resolved = await Self.resolve(locale) else { return false }
        return await SpeechAnalyzerProvider.assetsAreInstalled(
            for: SpeechAnalyzerProvider.transcriber(for: resolved),
            locale: resolved
        )
    }

    public func install(
        locale: Locale,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let resolved = await Self.resolve(locale) else {
            throw TranscriptionError.noSupportedLocale
        }
        let transcriber = SpeechAnalyzerProvider.transcriber(for: resolved)
        // Schon da heisst fertig: eine zweite Zustimmung soll nicht noch
        // einmal ein paar hundert Megabyte anfordern.
        if await SpeechAnalyzerProvider.assetsAreInstalled(
            for: transcriber,
            locale: resolved
        ) {
            progress(1)
            return
        }
        let modules: [any SpeechModule] = [transcriber]
        // Prozessweit serialisiert: die Einstellungen und ein anlaufender
        // Job duerfen dieselbe Sprache nicht zweimal gleichzeitig anfordern.
        do {
            try await AssetInstallationSerializer.shared.run(
                key: SpeechAnalyzerProvider.normalizedLocaleKey(resolved)
            ) {
                try await SpeechAnalyzerProvider.installAssets(
                    modules: modules,
                    locale: resolved,
                    progress: { step in
                        switch step {
                        case .checking:
                            progress(0)
                        case .downloading(_, let fractionCompleted):
                            progress(fractionCompleted)
                        case .installed:
                            progress(1)
                        }
                    }
                )
            }
        } catch {
            // Ein abgebrochener Transfer kommt bei Apple nicht verlaesslich
            // als `CancellationError` zurueck. Nur wenn wirklich abgebrochen
            // wurde, damit echte Netz- und Systemfehler sichtbar bleiben.
            try Task.checkCancellation()
            throw error
        }
        progress(1)
    }

    /// Dieselbe Aufloesung wie im Transkriptionslauf: "de-DE" und "de_DE"
    /// meinen dasselbe Asset, und eine nicht unterstuetzte Sprache soll hier
    /// scheitern und nicht erst beim ersten Meeting.
    private static func resolve(_ locale: Locale) async -> Locale? {
        LocaleResolver.select(
            requested: locale,
            supported: await SpeechTranscriber.supportedLocales
        )
    }
}
