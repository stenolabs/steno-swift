import Foundation

/// The pinned identity and exact contents expected for one locally imported Gemma snapshot.
///
/// This value is Steno configuration, not metadata trusted from a model directory.
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
        guard Self.isSafeModelIdentifier(modelIdentifier) else {
            throw GemmaModelVerificationError.invalidRequirement("modelIdentifier is unsafe")
        }
        guard Self.isGitRevision(checkpointRevision) else {
            throw GemmaModelVerificationError.invalidRequirement(
                "checkpointRevision must be exactly 40 lowercase hexadecimal characters"
            )
        }
        guard Self.isGitRevision(adapterRevision) else {
            throw GemmaModelVerificationError.invalidRequirement(
                "adapterRevision must be exactly 40 lowercase hexadecimal characters"
            )
        }
        guard Self.isSafeLicenseIdentifier(licenseIdentifier) else {
            throw GemmaModelVerificationError.invalidRequirement("licenseIdentifier is unsafe")
        }
        guard Self.isSHA256(expectedManifestSHA256) else {
            throw GemmaModelVerificationError.invalidRequirement(
                "expectedManifestSHA256 must be a lowercase SHA-256 digest"
            )
        }

        try GemmaModelManifest.validateRelativePath(manifestFileName)

        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.manifestFileName = manifestFileName
        self.expectedManifestSHA256 = expectedManifestSHA256
    }

    static func isGitRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(Self.isLowercaseHexDigit)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowercaseHexDigit)
    }

    static func isSafeModelIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 256 else { return false }
        guard bytes.allSatisfy({ byte in
            Self.isASCIIAlphaNumeric(byte) || [45, 46, 47, 95].contains(byte)
        }) else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func isSafeLicenseIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            Self.isASCIIAlphaNumeric(byte) || [43, 45, 46, 58, 95].contains(byte)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
    }
}

/// The portable manifest stored beside a locally imported Gemma model snapshot.
public struct GemmaModelManifest: Sendable, Equatable, Codable {
    public static let currentFormatVersion = 1
    public static let maximumManifestByteCount = 4 * 1024 * 1024
    public static let maximumFileCount = 4_096
    public static let maximumDirectoryCount = 64
    public static let maximumPathDepth = 8
    public static let maximumPathByteCount = 1_024
    public static let maximumPathComponentByteCount = 255

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

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case modelIdentifier
        case checkpointRevision
        case adapterRevision
        case licenseIdentifier
        case files
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        checkpointRevision = try container.decode(String.self, forKey: .checkpointRevision)
        adapterRevision = try container.decode(String.self, forKey: .adapterRevision)
        licenseIdentifier = try container.decode(String.self, forKey: .licenseIdentifier)

        var filesContainer = try container.nestedUnkeyedContainer(forKey: .files)
        var decodedFiles: [GemmaModelFile] = []
        while !filesContainer.isAtEnd {
            guard decodedFiles.count < Self.maximumFileCount else {
                throw GemmaModelVerificationError.tooManyFiles(
                    limit: Self.maximumFileCount,
                    actual: Self.maximumFileCount + 1
                )
            }
            decodedFiles.append(try filesContainer.decode(GemmaModelFile.self))
        }
        files = decodedFiles
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(checkpointRevision, forKey: .checkpointRevision)
        try container.encode(adapterRevision, forKey: .adapterRevision)
        try container.encode(licenseIdentifier, forKey: .licenseIdentifier)
        try container.encode(files, forKey: .files)
    }

    static func decode(from data: Data) throws -> GemmaModelManifest {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as GemmaModelVerificationError {
            if case .tooManyFiles(_, _) = error {
                throw error
            }
            throw GemmaModelVerificationError.malformedManifest
        } catch {
            throw GemmaModelVerificationError.malformedManifest
        }
    }

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

    /// Classifies the safetensors extension without case folding.
    static func isSafetensorsFile(_ path: String) -> Bool {
        path.hasSuffix(".safetensors")
    }

    static func validateRelativePath(_ value: String) throws {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count <= maximumPathByteCount,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              bytes.allSatisfy({ (0x21 ... 0x7e).contains($0) && $0 != 0x5c && $0 != 0x3a })
        else {
            throw GemmaModelVerificationError.invalidRelativePath(value)
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= maximumPathDepth,
              !components.contains(where: {
                  $0.isEmpty || $0.hasPrefix(".") || $0.utf8.count > maximumPathComponentByteCount
              })
        else {
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
        guard GemmaModelRequirements.isSafeModelIdentifier(modelIdentifier) else {
            throw GemmaModelVerificationError.unsafeModelIdentifier(modelIdentifier)
        }
        guard GemmaModelRequirements.isGitRevision(checkpointRevision) else {
            throw GemmaModelVerificationError.invalidCheckpointRevision(checkpointRevision)
        }
        guard GemmaModelRequirements.isGitRevision(adapterRevision) else {
            throw GemmaModelVerificationError.invalidAdapterRevision(adapterRevision)
        }
        guard !licenseIdentifier.isEmpty else {
            throw GemmaModelVerificationError.emptyLicenseIdentifier
        }
        guard GemmaModelRequirements.isSafeLicenseIdentifier(licenseIdentifier) else {
            throw GemmaModelVerificationError.unsafeLicenseIdentifier(licenseIdentifier)
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
        guard licenseIdentifier == requirements.licenseIdentifier else {
            throw GemmaModelVerificationError.licenseIdentifierMismatch(
                expected: requirements.licenseIdentifier,
                actual: licenseIdentifier
            )
        }
        guard !files.isEmpty else {
            throw GemmaModelVerificationError.emptyFileManifest
        }
        guard files.count <= Self.maximumFileCount else {
            throw GemmaModelVerificationError.tooManyFiles(
                limit: Self.maximumFileCount,
                actual: files.count
            )
        }

        var exactFilePaths = Set<String>()
        let reservedParents = Set(Self.parentDirectories(of: requirements.manifestFileName))
        var canonicalEntries = Dictionary(
            uniqueKeysWithValues: Self.pathAndParents(requirements.manifestFileName).map {
                (Self.canonicalPathKey($0), $0)
            }
        )
        for file in files {
            try Self.validateRelativePath(file.relativePath)
            guard file.relativePath != requirements.manifestFileName else {
                throw GemmaModelVerificationError.manifestPathReserved(file.relativePath)
            }
            guard file.size >= 0 else {
                throw GemmaModelVerificationError.invalidFileSize(
                    path: file.relativePath,
                    size: file.size
                )
            }
            guard GemmaModelRequirements.isSHA256(file.sha256) else {
                throw GemmaModelVerificationError.invalidFileChecksum(
                    path: file.relativePath,
                    checksum: file.sha256
                )
            }
            guard exactFilePaths.insert(file.relativePath).inserted else {
                throw GemmaModelVerificationError.duplicateManifestPath(file.relativePath)
            }
            if let reservedParent = reservedParents.first(where: { $0 == file.relativePath }) {
                throw GemmaModelVerificationError.pathCollision(
                    first: reservedParent,
                    second: requirements.manifestFileName
                )
            }
            if Self.parentDirectories(of: file.relativePath).contains(requirements.manifestFileName) {
                throw GemmaModelVerificationError.pathCollision(
                    first: requirements.manifestFileName,
                    second: file.relativePath
                )
            }

            for entry in Self.pathAndParents(file.relativePath) {
                let canonical = Self.canonicalPathKey(entry)
                if let first = canonicalEntries[canonical], first != entry {
                    throw GemmaModelVerificationError.pathCollision(first: first, second: entry)
                }
                canonicalEntries[canonical] = entry
            }
        }

        for path in exactFilePaths {
            for parent in Self.parentDirectories(of: path) where exactFilePaths.contains(parent) {
                throw GemmaModelVerificationError.pathCollision(first: parent, second: path)
            }
        }

        let directories = Set(
            files.flatMap { Self.parentDirectories(of: $0.relativePath) }
                + Self.parentDirectories(of: requirements.manifestFileName)
        )
        guard directories.count <= Self.maximumDirectoryCount else {
            throw GemmaModelVerificationError.tooManyDirectories(
                limit: Self.maximumDirectoryCount,
                actual: directories.count
            )
        }
    }

    static func parentDirectories(of path: String) -> [String] {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return [] }
        return (1 ..< components.count).map { components.prefix($0).joined(separator: "/") }
    }

    private static func pathAndParents(_ path: String) -> [String] {
        parentDirectories(of: path) + [path]
    }

    private static func canonicalPathKey(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}

public enum GemmaModelVerificationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequirement(String)
    case invalidRootDescriptor
    case rootDescriptorNotReadOnly
    case rootIsNotDirectory
    case rootIdentityMismatch
    case symbolicLinkNotAllowed(String)
    case unsupportedDirectoryEntry(String)
    case unsafeOwnership(String)
    case unsafePermissions(path: String, expected: UInt16, actual: UInt16)
    case hardLinkNotAllowed(String)
    case entryChanged(String)
    case manifestFileMissing(String)
    case manifestTooLarge(limit: Int, actualAtLeast: Int)
    case manifestDigestMismatch(expected: String, actual: String)
    case malformedManifest
    case malformedSafetensorsIndex
    case unsafeSafetensorsIndexPath(String)
    case unmanifestedSafetensorsFile(String)
    case unsupportedFormatVersion(expected: Int, actual: Int)
    case unsafeModelIdentifier(String)
    case invalidCheckpointRevision(String)
    case invalidAdapterRevision(String)
    case modelIdentifierMismatch(expected: String, actual: String)
    case checkpointRevisionMismatch(expected: String, actual: String)
    case adapterRevisionMismatch(expected: String, actual: String)
    case emptyLicenseIdentifier
    case unsafeLicenseIdentifier(String)
    case licenseIdentifierMismatch(expected: String, actual: String)
    case emptyFileManifest
    case tooManyFiles(limit: Int, actual: Int)
    case tooManyDirectories(limit: Int, actual: Int)
    case invalidRelativePath(String)
    case duplicateManifestPath(String)
    case pathCollision(first: String, second: String)
    case invalidFileSize(path: String, size: Int64)
    case invalidFileChecksum(path: String, checksum: String)
    case manifestPathReserved(String)
    case unexpectedDirectory(String)
    case missingFile(String)
    case unexpectedFile(String)
    case fileSizeMismatch(path: String, expected: Int64, actual: Int64)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case unreadableFile(String)
    case invalidActivationLimits
    case activationSmallFileTooLarge(path: String, limit: Int, actual: Int)
    case activationSmallFilesTooLarge(limit: Int, actualAtLeast: Int)
    case activationSafetensorsFileTooLarge(path: String, limit: Int64, actual: Int64)
    case activationSafetensorsFilesTooLarge(limit: Int64, actualAtLeast: Int64)
    case tooManyActivationSafetensorsFiles(limit: Int, actual: Int)
    case activationAssetsUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidRequirement(let detail):
            "Invalid Gemma model requirements: \(detail)."
        case .invalidRootDescriptor:
            "The Gemma model root descriptor is invalid."
        case .rootDescriptorNotReadOnly:
            "The Gemma model root descriptor is not read-only."
        case .rootIsNotDirectory:
            "The Gemma model root is not a directory."
        case .rootIdentityMismatch:
            "The Gemma model root is not the expected directory."
        case .symbolicLinkNotAllowed(let path):
            "Gemma model snapshots must not contain symbolic links: \(path)."
        case .unsupportedDirectoryEntry(let path):
            "Gemma model snapshots may contain only regular files and directories: \(path)."
        case .unsafeOwnership(let path):
            "A Gemma model snapshot entry is not owned by the current user: \(path)."
        case .unsafePermissions(let path, let expected, let actual):
            "A Gemma model snapshot entry has unsafe permissions at \(path): expected \(String(expected, radix: 8)), found \(String(actual, radix: 8))."
        case .hardLinkNotAllowed(let path):
            "Gemma model snapshot files must not be hard linked: \(path)."
        case .entryChanged(let path):
            "A Gemma model snapshot entry changed during verification: \(path)."
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
        case .unsafeModelIdentifier:
            "The Gemma model manifest contains an unsafe model identifier."
        case .invalidCheckpointRevision:
            "The Gemma model manifest checkpoint revision is not a pinned Git revision."
        case .invalidAdapterRevision:
            "The Gemma model manifest adapter revision is not a pinned Git revision."
        case .modelIdentifierMismatch:
            "The Gemma model identifier does not match the selected model."
        case .checkpointRevisionMismatch:
            "The Gemma checkpoint revision does not match the selected model."
        case .adapterRevisionMismatch:
            "The Gemma adapter revision does not match the selected model."
        case .emptyLicenseIdentifier:
            "The Gemma model manifest does not declare a license identifier."
        case .unsafeLicenseIdentifier:
            "The Gemma model manifest contains an unsafe license identifier."
        case .licenseIdentifierMismatch:
            "The Gemma model license identifier does not match the selected model."
        case .emptyFileManifest:
            "The Gemma model manifest does not list any files."
        case .tooManyFiles(let limit, _):
            "The Gemma model manifest lists more than \(limit) files."
        case .tooManyDirectories(let limit, _):
            "The Gemma model manifest requires more than \(limit) directories."
        case .invalidRelativePath(let path):
            "The Gemma model manifest contains an unsafe relative path: \(path)."
        case .duplicateManifestPath(let path):
            "The Gemma model manifest lists a file more than once: \(path)."
        case .pathCollision(let first, let second):
            "The Gemma model manifest contains colliding paths: \(first) and \(second)."
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
        case .invalidActivationLimits:
            "The Gemma activation limits are invalid."
        case .activationSmallFileTooLarge(let path, let limit, _):
            "The Gemma activation file \(path) exceeds the \(limit)-byte small-file limit."
        case .activationSmallFilesTooLarge(let limit, _):
            "Gemma activation small files exceed the \(limit)-byte total limit."
        case .activationSafetensorsFileTooLarge(let path, let limit, _):
            "The Gemma safetensors file \(path) exceeds the \(limit)-byte limit."
        case .activationSafetensorsFilesTooLarge(let limit, _):
            "Gemma safetensors files exceed the \(limit)-byte total limit."
        case .tooManyActivationSafetensorsFiles(let limit, _):
            "Gemma activation has more than \(limit) safetensors files."
        case .activationAssetsUnavailable:
            "The Gemma activation assets are closed or already consumed."
        }
    }
}
