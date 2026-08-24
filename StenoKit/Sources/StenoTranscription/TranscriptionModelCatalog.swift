import Foundation
import StenoDomain

public struct TranscriptionModelCatalog: Sendable {
    public static let standard = Self(descriptors: [
        TranscriptionModelDescriptor(
            id: .apple,
            displayName: "Apple Speech Analyzer",
            vendor: "Apple",
            maturity: .production,
            supportsLive: true,
            supportsFinal: true,
            supportedLanguageCodes: nil,
            approximateDownloadBytes: nil
        ),
        TranscriptionModelDescriptor(
            id: .parakeetTDTv3,
            displayName: "FluidAudio Parakeet TDT",
            vendor: "FluidInference",
            maturity: .experimental,
            supportsLive: true,
            supportsFinal: true,
            supportedLanguageCodes: [
                "en", "es", "fr", "de", "it", "pt", "ro", "nl",
                "da", "sv", "fi", "hu", "et", "lv", "lt", "mt",
                "pl", "cs", "sk", "sl", "hr", "bs", "ru", "uk",
                "be", "bg", "sr", "el",
            ],
            approximateDownloadBytes: 483_307_520
        ),
    ])

    public let descriptors: [TranscriptionModelDescriptor]

    public init(descriptors: [TranscriptionModelDescriptor]) {
        self.descriptors = descriptors
    }

    public func defaultProvider(for use: TranscriptionUse) -> TranscriptionProviderID {
        .apple
    }

    public func descriptor(for id: TranscriptionProviderID) -> TranscriptionModelDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Prüft, ob der Provider für Anwendungsfall und Sprache infrage kommt.
    /// Die Locale kommt immer vom Aufrufer aus der gespeicherten Wahl
    /// (`Meeting.sourceLocale`, `Job.localeIdentifier`), niemals aus
    /// `Locale.current` - der System-Locale ist nicht die gesprochene Sprache.
    public func supports(
        _ id: TranscriptionProviderID,
        use: TranscriptionUse,
        locale: Locale,
        experimentalLiveEnabled: Bool
    ) -> Bool {
        guard let descriptor = descriptor(for: id) else {
            return false
        }

        switch use {
        case .live:
            guard descriptor.supportsLive else { return false }
            if descriptor.maturity == .experimental && !experimentalLiveEnabled {
                return false
            }
        case .final:
            guard descriptor.supportsFinal else { return false }
        }

        guard let supportedLanguageCodes = descriptor.supportedLanguageCodes else {
            return true
        }
        guard let languageCode = locale.language.languageCode?.identifier.lowercased() else {
            return false
        }
        return supportedLanguageCodes.contains(languageCode)
    }
}
