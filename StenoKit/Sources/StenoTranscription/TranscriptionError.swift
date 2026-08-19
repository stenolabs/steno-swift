import Foundation

public enum TranscriptionError: Error, Equatable, Sendable {
    case speechTranscriberUnavailable
    case noSupportedLocale
    case assetsUnsupported(localeIdentifier: String)
    /// Es fehlt schlicht die Installation, kein Installationsversuch ist
    /// gescheitert. Andere Aussage als `assetInstallationUnavailable`, und
    /// sie muss auch anders klingen: der Nutzer liest sie im Statusband.
    case assetsNotInstalled(localeIdentifier: String)
    case assetInstallationUnavailable(localeIdentifier: String)
    case noCompatibleAudioFormat
    case audioConversionFailed(String)
    case audioInputOverflow(capacity: Int)
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .speechTranscriberUnavailable:
            "SpeechTranscriber is unavailable on this device."
        case .noSupportedLocale:
            "SpeechTranscriber does not support any locale on this device."
        case .assetsUnsupported(let localeIdentifier):
            "Speech assets for locale \(localeIdentifier) are unsupported."
        case .assetsNotInstalled(let localeIdentifier):
            "The speech model for \(localeIdentifier) is not installed yet. Install it in Steno's settings."
        case .assetInstallationUnavailable(let localeIdentifier):
            "Speech assets for locale \(localeIdentifier) could not be installed."
        case .noCompatibleAudioFormat:
            "SpeechAnalyzer did not provide a compatible audio format."
        case .audioConversionFailed(let message):
            "Audio conversion for SpeechAnalyzer failed: \(message)"
        case .audioInputOverflow(let capacity):
            "SpeechAnalyzer could not keep up with the live audio buffer of \(capacity) chunks."
        }
    }
}

public enum AssetPreparationProgress: Equatable, Sendable {
    case checking(localeIdentifier: String)
    case downloading(localeIdentifier: String, fractionCompleted: Double)
    case installed(localeIdentifier: String)
}

public typealias AssetProgressHandler = @Sendable (AssetPreparationProgress) -> Void
