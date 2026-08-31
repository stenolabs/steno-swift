import Foundation

/// Immutable, path-free provenance for a Gemma checkpoint installed for
/// native MLX inference. The snapshot deliberately identifies model material
/// only. It never carries a local URL, cache directory, or executable path.
public struct NativeGemmaModelSnapshot: Codable, Equatable, Sendable {
    /// Reserved persisted marker for native Gemma jobs. It is not an external
    /// endpoint identifier and must never be resolved through an endpoint registry.
    public static let reservedTextModelEndpointID = "steno-native-gemma"

    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String

    public init(
        modelIdentifier: String,
        checkpointRevision: String,
        adapterRevision: String,
        licenseIdentifier: String,
        manifestSHA256: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.manifestSHA256 = manifestSHA256
    }

    /// A native job may execute only with a complete, canonical model pin.
    /// This remains a non-throwing check so malformed persisted legacy data
    /// can be decoded and then rejected at the execution boundary.
    public var isWellFormed: Bool {
        Self.isModelIdentifier(modelIdentifier)
            && Self.isRevision(checkpointRevision)
            && Self.isRevision(adapterRevision)
            && Self.isLicenseIdentifier(licenseIdentifier)
            && Self.isSHA256(manifestSHA256)
    }

    private static func isModelIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 256,
              !value.contains("://"),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\")
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(components.count) else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.allSatisfy(Self.isIdentifierByte)
        }
    }

    private static func isRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(Self.isLowercaseHexByte)
    }

    private static func isLicenseIdentifier(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.utf8.count),
              let first = value.utf8.first,
              Self.isASCIIAlphaNumeric(first)
        else { return false }
        return value.utf8.allSatisfy { byte in
            Self.isASCIIAlphaNumeric(byte) || [43, 45, 46, 95].contains(byte)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowercaseHexByte)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        Self.isASCIIAlphaNumeric(byte) || [45, 46, 95].contains(byte)
    }

    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
    }
}
