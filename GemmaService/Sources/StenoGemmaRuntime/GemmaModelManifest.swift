import CryptoKit
import Foundation

/// The pinned identity and exact contents expected for one locally imported Gemma snapshot.
///
/// This value is configuration supplied by Steno, not metadata supplied by a model directory.
/// A model directory is accepted only when its manifest bytes and decoded identity exactly match it.
public struct GemmaModelRequirements: Sendable, Equatable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestFileName: String
    public let expectedManifestSHA256: String

    public init(
        modelIdentifier: String,
        checkpointRevision: String,
        adapterRevision: String,
        licenseIdentifier: String,
        manifestFileName: String = "gemma-model-manifest.json",
        expectedManifestSHA256: String
    ) throws {
        guard !modelIdentifier.isEmpty else {
            throw GemmaModelVerificationError.invalidRequirement("modelIdentifier must not be empty")
        }
        guard !checkpointRevision.isEmpty else {
            throw GemmaModelVerificationError.invalidRequirement("checkpointRevision must not be empty")
        }
        guard !adapterRevision.isEmpty else {
            throw GemmaModelVerificationError.invalidRequirement("adapterRevision must not be empty")
        }
        guard !licenseIdentifier.isEmpty else {
            throw GemmaModelVerificationError.invalidRequirement("licenseIdentifier must not be empty")
        }
        guard Self.isSHA256(expectedManifestSHA256) else {
            throw GemmaModelVerificationError.invalidRequirement("expectedManifestSHA256 must be a lowercase SHA-256 digest")
        }

        try GemmaModelManifest.validateRelativePath(manifestFileName)

        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.manifestFileName = manifestFileName
        self.expectedManifestSHA256 = expectedManifestSHA256
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

/// The portable manifest stored beside a locally imported Gemma model snapshot.
public struct GemmaModelManifest: Sendable, Equatable, Codable {
    public static let currentFormatVersion = 1
    public static let maximumManifestByteCount = 4 * 1024 * 1024

    public let formatVersion: Int
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let files: [GemmaModelFile]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        modelIdentifier: String,
        checkpointRevision: String,
        adapterRevision: String,
        licenseIdentifier: String,
        files: [GemmaModelFile]
    ) {
        self.formatVersion = formatVersion
        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.files = files
    }

    /// A single regular file that must be present in a verified snapshot.
    public struct GemmaModelFile: Sendable, Equatable, Codable {
        public let relativePath: String
        public let size: Int64
        public let sha256: String

        public init(relativePath: String, size: Int64, sha256: String) {
            self.relativePath = relativePath
            self.size = size
            self.sha256 = sha256
        }
    }

    static func validateRelativePath(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") else {
            throw GemmaModelVerificationError.invalidRelativePath(value)
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw GemmaModelVerificationError.invalidRelativePath(value)
        }
    }

    func validate(against requirements: GemmaModelRequirements) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw GemmaModelVerificationError.unsupportedFormatVersion(
                expected: Self.currentFormatVersion,
                actual: formatVersion
            )
        }
        guard modelIdentifier == requirements.modelIdentifier else {
            throw GemmaModelVerificationError.modelIdentifierMismatch(
                expected: requirements.modelIdentifier,
                actual: modelIdentifier
            )
        }
        guard checkpointRevision == requirements.checkpointRevision else {
            throw GemmaModelVerificationError.checkpointRevisionMismatch(
                expected: requirements.checkpointRevision,
                actual: checkpointRevision
            )
        }
        guard adapterRevision == requirements.adapterRevision else {
            throw GemmaModelVerificationError.adapterRevisionMismatch(
                expected: requirements.adapterRevision,
                actual: adapterRevision
            )
        }
        guard !licenseIdentifier.isEmpty else {
            throw GemmaModelVerificationError.emptyLicenseIdentifier
        }
        guard licenseIdentifier == requirements.licenseIdentifier else {
            throw GemmaModelVerificationError.licenseIdentifierMismatch(
                expected: requirements.licenseIdentifier,
                actual: licenseIdentifier
            )
        }
        guard !files.isEmpty else {
            throw GemmaModelVerificationError.emptyFileManifest
        }

        var paths = Set<String>()
        for file in files {
            try Self.validateRelativePath(file.relativePath)
            guard file.relativePath != requirements.manifestFileName else {
                throw GemmaModelVerificationError.manifestPathReserved(file.relativePath)
            }
            guard file.size >= 0 else {
                throw GemmaModelVerificationError.invalidFileSize(path: file.relativePath, size: file.size)
            }
            guard GemmaModelRequirements.isSHA256(file.sha256) else {
                throw GemmaModelVerificationError.invalidFileChecksum(path: file.relativePath, checksum: file.sha256)
            }
            guard paths.insert(file.relativePath).inserted else {
                throw GemmaModelVerificationError.duplicateManifestPath(file.relativePath)
            }
        }
    }
}

/// Errors produced while rejecting an incomplete, altered, or unsafe local model snapshot.
public enum GemmaModelVerificationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequirement(String)
    case rootIsNotDirectory
    case symbolicLinkNotAllowed(String)
    case unsupportedDirectoryEntry(String)
    case manifestFileMissing(String)
    case manifestTooLarge(limit: Int, actualAtLeast: Int)
    case manifestDigestMismatch(expected: String, actual: String)
    case malformedManifest
    case malformedSafetensorsIndex
    case unsafeSafetensorsIndexPath(String)
    case unmanifestedSafetensorsFile(String)
    case unsupportedFormatVersion(expected: Int, actual: Int)
    case modelIdentifierMismatch(expected: String, actual: String)
    case checkpointRevisionMismatch(expected: String, actual: String)
    case adapterRevisionMismatch(expected: String, actual: String)
    case emptyLicenseIdentifier
    case licenseIdentifierMismatch(expected: String, actual: String)
    case emptyFileManifest
    case invalidRelativePath(String)
    case duplicateManifestPath(String)
    case invalidFileSize(path: String, size: Int64)
    case invalidFileChecksum(path: String, checksum: String)
    case manifestPathReserved(String)
    case unexpectedDirectory(String)
    case missingFile(String)
    case unexpectedFile(String)
    case fileSizeMismatch(path: String, expected: Int64, actual: Int64)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequirement(let detail):
            "Invalid Gemma model requirements: \(detail)."
        case .rootIsNotDirectory:
            "The Gemma model root is not a directory."
        case .symbolicLinkNotAllowed(let path):
            "Gemma model snapshots must not contain symbolic links: \(path)."
        case .unsupportedDirectoryEntry(let path):
            "Gemma model snapshots may contain only regular files and directories: \(path)."
        case .manifestFileMissing(let path):
            "The Gemma model manifest is missing: \(path)."
        case .manifestTooLarge(let limit, _):
            "The Gemma model manifest exceeds the \(limit)-byte size limit."
        case .manifestDigestMismatch:
            "The Gemma model manifest does not match the pinned digest."
        case .malformedManifest:
            "The Gemma model manifest is malformed."
        case .malformedSafetensorsIndex:
            "The Gemma safetensors index is malformed."
        case .unsafeSafetensorsIndexPath(let path):
            "The Gemma safetensors index contains an unsafe path: \(path)."
        case .unmanifestedSafetensorsFile(let path):
            "The Gemma safetensors index references an unmanifested file: \(path)."
        case .unsupportedFormatVersion:
            "The Gemma model manifest format is unsupported."
        case .modelIdentifierMismatch:
            "The Gemma model identifier does not match the selected model."
        case .checkpointRevisionMismatch:
            "The Gemma checkpoint revision does not match the selected model."
        case .adapterRevisionMismatch:
            "The Gemma adapter revision does not match the selected model."
        case .emptyLicenseIdentifier:
            "The Gemma model manifest does not declare a license identifier."
        case .licenseIdentifierMismatch:
            "The Gemma model license identifier does not match the selected model."
        case .emptyFileManifest:
            "The Gemma model manifest does not list any files."
        case .invalidRelativePath(let path):
            "The Gemma model manifest contains an unsafe relative path: \(path)."
        case .duplicateManifestPath(let path):
            "The Gemma model manifest lists a file more than once: \(path)."
        case .invalidFileSize(let path, _):
            "The Gemma model manifest contains an invalid size for \(path)."
        case .invalidFileChecksum(let path, _):
            "The Gemma model manifest contains an invalid checksum for \(path)."
        case .manifestPathReserved(let path):
            "The Gemma model manifest cannot list itself as a model file: \(path)."
        case .unexpectedDirectory(let path):
            "The Gemma model snapshot contains an unexpected directory: \(path)."
        case .missingFile(let path):
            "A Gemma model file is missing: \(path)."
        case .unexpectedFile(let path):
            "The Gemma model snapshot contains an unexpected file: \(path)."
        case .fileSizeMismatch(let path, _, _):
            "A Gemma model file has an unexpected size: \(path)."
        case .fileHashMismatch(let path, _, _):
            "A Gemma model file does not match the expected checksum: \(path)."
        case .unreadableFile(let path):
            "A Gemma model file cannot be read: \(path)."
        }
    }
}
