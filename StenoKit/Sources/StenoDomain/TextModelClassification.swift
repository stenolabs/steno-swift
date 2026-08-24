import Foundation

/// Wo ein konfigurierter Textmodell-Endpunkt laeuft. Die einzige Stelle, an
/// der der Nutzer erkennt, ob eine Besprechung das Geraet verlaesst - siehe
/// `TextModelEndpointPolicy.inferredHosting(for:)` fuer die Herleitung.
public enum TextModelHosting: String, Codable, CaseIterable, Equatable, Sendable {
    case onDevice
    case selfHosted
    case cloud

    public var displayName: String {
        switch self {
        case .onDevice:
            "On this device"
        case .selfHosted:
            "Self-hosted"
        case .cloud:
            "Cloud service"
        }
    }
}

/// Das API-Format eines konfigurierten Endpunkts. In S4 ist ausschliesslich
/// `openAICompatible` konfigurierbar; die uebrigen Faelle schaltet
/// `TextModelEndpointPolicy` erst in spaeteren Schritten frei.
public enum TextModelAPIDialect: String, Codable, CaseIterable, Equatable, Sendable {
    case ollama
    case lmStudio
    case openAI
    case anthropic
    case amazonBedrock
    case openAICompatible

    public var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .amazonBedrock: "Amazon Bedrock"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    public var defaultBaseURL: URL? {
        switch self {
        case .ollama:
            URL(string: "http://localhost:11434")
        case .lmStudio:
            URL(string: "http://localhost:1234/v1")
        case .openAICompatible:
            URL(string: "http://localhost:8080/v1")
        case .openAI:
            URL(string: "https://api.openai.com/v1")
        case .anthropic:
            URL(string: "https://api.anthropic.com/v1")
        case .amazonBedrock:
            nil
        }
    }

    /// Womit ein neuer Endpunkt dieses Dialekts startet.
    ///
    /// Nur Ollama bekommt mehr als das Minimum, und zwar weil Steno ihm die
    /// Groesse ueber `num_ctx` tatsaechlich vorgeben kann. Wo das nicht geht,
    /// etwa beim generischen OpenAI-Dialekt, waere ein grosser Wert eine
    /// Behauptung ueber einen Server, der davon nichts weiss: er bliebe bei
    /// seiner eigenen Groesse und schnitte die Prompts still ab.
    ///
    /// 4096 reichen fuer eine Besprechung von Laenge nicht. Gemessen an einer
    /// von 3:37 h brach der Lauf damit nach 192 Anfragen ab, weil die
    /// Zwischenergebnisse nicht mehr zu zweit in eine Anfrage passten; mit
    /// 32768 lief er in zehn Anfragen durch. Ollama deckelt einen zu grossen
    /// Wert von sich aus auf das Maximum des Modells, und der Zuschlag an
    /// Speicher ist klein - auf einer 12-GB-Karte kostete der Sprung von 4096
    /// auf 32768 bei gemma4:12b 476 MiB. Reicht der Speicher doch nicht,
    /// lagert Ollama auf die CPU aus: langsamer, nicht kaputt.
    public var defaultContextWindowTokens: Int {
        switch self {
        case .ollama: 32_768
        case .lmStudio, .openAI, .anthropic, .amazonBedrock, .openAICompatible: 4_096
        }
    }

    public static let configurableLocalCases: [Self] = [
        .ollama,
        .lmStudio,
        .openAICompatible,
    ]

    public static let configurableCloudCases: [Self] = [
        .openAI,
        .anthropic,
        .amazonBedrock,
    ]

    public static let configurableCases = configurableLocalCases + configurableCloudCases
}

/// Zusatzangaben fuer Endpunkte mit Dialekt `amazonBedrock`. Fuer alle
/// anderen Dialekte weist `TextModelEndpointPolicy` diese Konfiguration ab.
public struct AmazonBedrockConfiguration: Codable, Equatable, Sendable {
    public let region: String
    public let inferenceProfile: String?

    public init(region: String, inferenceProfile: String?) {
        self.region = region
        self.inferenceProfile = inferenceProfile
    }
}
