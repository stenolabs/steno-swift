import Foundation
import Network

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

    public static func validate(_ endpoint: TextModelEndpoint) throws -> TextModelEndpoint {
        _ = try transportSecurity(for: endpoint.baseURL)
        return endpoint
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
