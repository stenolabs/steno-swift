public struct TranscriptionProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let apple = Self(rawValue: "apple.speech-analyzer")
    public static let parakeetTDTv3 = Self(rawValue: "fluidaudio.parakeet-tdt-v3")
}

public enum TranscriptionUse: String, Codable, Sendable {
    case live
    case final
}

public enum TranscriptionModelMaturity: String, Codable, Sendable {
    case production
    case experimental
}

public struct TranscriptionModelDescriptor: Equatable, Sendable {
    public let id: TranscriptionProviderID
    public let displayName: String
    public let vendor: String
    public let maturity: TranscriptionModelMaturity
    public let supportsLive: Bool
    public let supportsFinal: Bool
    public let supportedLanguageCodes: Set<String>?
    public let approximateDownloadBytes: Int?

    public init(
        id: TranscriptionProviderID,
        displayName: String,
        vendor: String,
        maturity: TranscriptionModelMaturity,
        supportsLive: Bool,
        supportsFinal: Bool,
        supportedLanguageCodes: Set<String>?,
        approximateDownloadBytes: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.maturity = maturity
        self.supportsLive = supportsLive
        self.supportsFinal = supportsFinal
        self.supportedLanguageCodes = supportedLanguageCodes
        self.approximateDownloadBytes = approximateDownloadBytes
    }
}
