import Foundation
import Network
import StenoDomain

public enum TextModelTransportSecurity: Equatable, Sendable {
    case encrypted
    case localPlaintext
}

public enum TextModelEndpointPolicyError: Error, Equatable, Sendable {
    case missingHost
    case unsupportedScheme
    case embeddedCredentials
    case queryNotAllowed
    case fragmentNotAllowed
    case insecureRemoteURL
    case invalidHosting
    case invalidProviderConfiguration
    case unsupportedDialect(TextModelAPIDialect)
    case invalidContextWindow
}

public enum TextModelEndpointPolicy {
    public static func transportSecurity(for url: URL) throws -> TextModelTransportSecurity {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else {
            throw TextModelEndpointPolicyError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw TextModelEndpointPolicyError.embeddedCredentials
        }
        guard components.query == nil else {
            throw TextModelEndpointPolicyError.queryNotAllowed
        }
        guard components.fragment == nil else {
            throw TextModelEndpointPolicyError.fragmentNotAllowed
        }
        guard let host = components.host, !host.isEmpty else {
            throw TextModelEndpointPolicyError.missingHost
        }
        switch scheme {
        case "https":
            return .encrypted
        case "http":
            guard isLocalHost(host) else {
                throw TextModelEndpointPolicyError.insecureRemoteURL
            }
            return .localPlaintext
        default:
            throw TextModelEndpointPolicyError.unsupportedScheme
        }
    }

    /// Die einzige Inferenzstelle fuer die Hosting-Anzeige. Nur beweisbares
    /// Loopback (localhost, 127.0.0.0/8, ::1) gilt als selfHosted; alles
    /// Unentscheidbare, auch private Bereiche wie RFC1918 und .local, wird
    /// cloud. Eine private Adresse kann ueber ein VPN in fremde
    /// Infrastruktur fuehren, und falsch-extern ist der einzig vertretbare
    /// Fehler. Der Decode-Fallback und die Draft-Vorbelegung rufen diese
    /// Funktion, es gibt keine zweite Inferenz.
    public static func inferredHosting(for url: URL) -> TextModelHosting {
        guard let host = url.host, !host.isEmpty else { return .cloud }
        return isProvableLoopback(host) ? .selfHosted : .cloud
    }

    /// Ein Endpunkt, den Steno besser mit einem anderen Dialekt anspraeche.
    public struct NativeDialectSuggestion: Equatable, Sendable {
        public let dialect: TextModelAPIDialect
        public let baseURL: URL
    }

    /// Ollama laesst sich auch ueber seine OpenAI-kompatible Schicht
    /// ansprechen, aber dort fehlen zwei Stellschrauben, die der eigene
    /// Dialekt hat: den Denkmodus abschalten und die Kontextgroesse setzen.
    /// Bei einem Modell mit Denkmodus ist das der Unterschied zwischen einem
    /// Ergebnis und gar keinem - das Budget geht sonst in die Gedanken, und
    /// zurueck kommt eine leere Antwort.
    ///
    /// Der Port ist dafuer ein Indiz und kein Beweis, also aendert diese
    /// Funktion nichts, sondern schlaegt vor. Sie schweigt, sobald der
    /// Endpunkt einen Dialekt fuehrt, der eine bewusste Wahl sein kann.
    public static func nativeDialectSuggestion(
        baseURL: URL,
        dialect: TextModelAPIDialect
    ) -> NativeDialectSuggestion? {
        guard dialect == .openAICompatible,
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.port == ollamaDefaultPort
        else { return nil }
        return NativeDialectSuggestion(
            dialect: .ollama,
            baseURL: nativeRoot(baseURL)
        )
    }

    /// Der native Pfad haengt seine Route selbst an, das `/v1` der
    /// OpenAI-Schicht gehoert dann nicht mehr in die Basis-URL.
    private static func nativeRoot(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var path = components.percentEncodedPath
        if path.hasSuffix("/v1/") {
            path.removeLast(4)
        } else if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.percentEncodedPath = path
        return components.url ?? url
    }

    private static let ollamaDefaultPort = 11_434

    public static func validate(_ endpoint: TextModelEndpoint) throws -> TextModelEndpoint {
        _ = try transportSecurity(for: endpoint.baseURL)
        guard endpoint.hosting != .onDevice else {
            throw TextModelEndpointPolicyError.invalidHosting
        }
        guard endpoint.dialect == .amazonBedrock || endpoint.bedrock == nil else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        // Bedrock-Sonderpolicy: ohne Bedrock-Konfiguration kann
        // AmazonBedrockProvider keine gueltige Converse-URL bauen, und eine
        // Basis-URL, die nicht zur konfigurierten Region passt, wuerde
        // Anfragen unbemerkt an die falsche Region schicken.
        if endpoint.dialect == .amazonBedrock {
            guard let bedrock = endpoint.bedrock,
                  endpoint.baseURL == (try? AmazonBedrockEndpointPolicy.baseURL(
                      region: bedrock.region
                  ))
            else {
                throw TextModelEndpointPolicyError.invalidProviderConfiguration
            }
        }
        guard [
            .openAICompatible, .ollama, .lmStudio, .openAI, .anthropic, .amazonBedrock,
        ].contains(endpoint.dialect) else {
            throw TextModelEndpointPolicyError.unsupportedDialect(endpoint.dialect)
        }
        let supportedContextWindows = TextModelEndpoint.minimumContextWindowTokens
            ... TextModelEndpoint.maximumContextWindowTokens
        guard supportedContextWindows.contains(endpoint.contextWindowTokens) else {
            throw TextModelEndpointPolicyError.invalidContextWindow
        }
        return endpoint
    }

    private static func isProvableLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let octets = ipv4Octets(normalized) {
            return octets[0] == 127
        }
        let unbracketed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = IPv6Address(unbracketed) {
            return address.rawValue.dropLast().allSatisfy { $0 == 0 } && address.rawValue.last == 1
        }
        return normalized == "localhost"
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !isNumericSingleLabel(normalized) else { return false }
        if let octets = ipv4Octets(normalized) {
            return isLocalIPv4(octets)
        }
        let unbracketed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = IPv6Address(unbracketed) {
            return isLocalIPv6(address)
        }
        return normalized == "localhost"
            || normalized.hasSuffix(".local")
            || !normalized.contains(".")
    }

    private static func isNumericSingleLabel(_ host: String) -> Bool {
        guard !host.contains(".") else { return false }
        if host.allSatisfy(\.isNumber) {
            return true
        }
        return host.hasPrefix("0x")
            && host.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        octets[0] == 127
            || octets[0] == 10
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64 ... 127).contains(octets[1]))
    }

    private static func isLocalIPv6(_ address: IPv6Address) -> Bool {
        let bytes = address.rawValue
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
            return true
        }
        return bytes[0] & 0xfe == 0xfc || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    }
}
