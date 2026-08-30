import CryptoKit
import Foundation

/// Verifies local Gemma model snapshots without downloading, resolving, or loading a model.
public struct GemmaModelVerifier: Sendable {
    public let requirements: GemmaModelRequirements

    public init(requirements: GemmaModelRequirements) {
        self.requirements = requirements
    }

    /// Verifies a complete snapshot and returns a capability that a model factory can revalidate before loading.
    public func verify(directory: URL) throws -> VerifiedGemmaModel {
        let root = try verifiedRoot(directory: directory)
        return VerifiedGemmaModel(rootDirectory: root, requirements: requirements)
    }

    func verifiedRoot(directory: URL) throws -> URL {
        let root = directory.standardizedFileURL
        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        } catch {
            throw GemmaModelVerificationError.rootIsNotDirectory
        }
        if rootAttributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw GemmaModelVerificationError.symbolicLinkNotAllowed(".")
        }
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw GemmaModelVerificationError.rootIsNotDirectory
        }

        let manifestURL = root.appendingPathComponent(requirements.manifestFileName, isDirectory: false)
        let manifestData = try Self.readManifest(
            at: manifestURL,
            relativePath: requirements.manifestFileName
        )
        let manifestDigest = Self.sha256(manifestData)
        guard manifestDigest == requirements.expectedManifestSHA256 else {
            throw GemmaModelVerificationError.manifestDigestMismatch(
                expected: requirements.expectedManifestSHA256,
                actual: manifestDigest
            )
        }

        let manifest: GemmaModelManifest
        do {
            manifest = try JSONDecoder().decode(GemmaModelManifest.self, from: manifestData)
        } catch {
            throw GemmaModelVerificationError.malformedManifest
        }
        try manifest.validate(against: requirements)

        let entries = try snapshotEntries(in: root)
        let actualFiles = entries.files
        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
        let expectedPaths = Set(expectedFiles.keys).union([requirements.manifestFileName])
        let expectedDirectories = Set(
            expectedFiles.keys.flatMap(Self.parentDirectories(of:))
                + Self.parentDirectories(of: requirements.manifestFileName)
        )

        for path in actualFiles.keys.sorted() where !expectedPaths.contains(path) {
            throw GemmaModelVerificationError.unexpectedFile(path)
        }
        for path in entries.directories.sorted() where !expectedDirectories.contains(path) {
            throw GemmaModelVerificationError.unexpectedDirectory(path)
        }
        for path in expectedFiles.keys.sorted() where actualFiles[path] == nil {
            throw GemmaModelVerificationError.missingFile(path)
        }

        for path in expectedFiles.keys.sorted() {
            guard let file = expectedFiles[path], let url = actualFiles[path] else {
                throw GemmaModelVerificationError.missingFile(path)
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw GemmaModelVerificationError.unreadableFile(path)
            }
            guard let size = attributes[.size] as? NSNumber else {
                throw GemmaModelVerificationError.unreadableFile(path)
            }
            let actualSize = size.int64Value
            guard actualSize == file.size else {
                throw GemmaModelVerificationError.fileSizeMismatch(
                    path: path,
                    expected: file.size,
                    actual: actualSize
                )
            }
            let actualDigest = try Self.sha256(of: url, path: path)
            guard actualDigest == file.sha256 else {
                throw GemmaModelVerificationError.fileHashMismatch(
                    path: path,
                    expected: file.sha256,
                    actual: actualDigest
                )
            }
        }

        try Self.validateSafetensorsIndex(
            in: root,
            expectedFiles: expectedFiles
        )

        return root
    }

    private static func validateSafetensorsIndex(
        in root: URL,
        expectedFiles: [String: GemmaModelManifest.GemmaModelFile]
    ) throws {
        let indexPath = "model.safetensors.index.json"
        guard let expectedIndex = expectedFiles[indexPath] else { return }
        guard expectedIndex.size <= Int64(GemmaModelManifest.maximumManifestByteCount) else {
            throw GemmaModelVerificationError.malformedSafetensorsIndex
        }

        let indexURL = root.appendingPathComponent(indexPath, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            throw GemmaModelVerificationError.malformedSafetensorsIndex
        }
        guard Int64(data.count) == expectedIndex.size,
              sha256(data) == expectedIndex.sha256,
              let index = try? JSONDecoder().decode(SafetensorsIndex.self, from: data),
              !index.weightMap.isEmpty
        else {
            throw GemmaModelVerificationError.malformedSafetensorsIndex
        }

        for path in Set(index.weightMap.values).sorted() {
            do {
                try GemmaModelManifest.validateRelativePath(path)
            } catch {
                throw GemmaModelVerificationError.unsafeSafetensorsIndexPath(path)
            }
            guard path.hasSuffix(".safetensors"), expectedFiles[path] != nil else {
                throw GemmaModelVerificationError.unmanifestedSafetensorsFile(path)
            }
        }
    }

    private func snapshotEntries(in root: URL) throws -> SnapshotEntries {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw GemmaModelVerificationError.rootIsNotDirectory
        }

        var files: [String: URL] = [:]
        var directories = Set<String>()
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path

        while let url = enumerator.nextObject() as? URL {
            let relativePath = try Self.relativePath(of: url, below: rootPath)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw GemmaModelVerificationError.unreadableFile(relativePath)
            }
            guard let type = attributes[.type] as? FileAttributeType else {
                throw GemmaModelVerificationError.unsupportedDirectoryEntry(relativePath)
            }
            if type == .typeSymbolicLink {
                throw GemmaModelVerificationError.symbolicLinkNotAllowed(relativePath)
            }
            if type == .typeDirectory {
                directories.insert(relativePath)
                continue
            }
            guard type == .typeRegular else {
                throw GemmaModelVerificationError.unsupportedDirectoryEntry(relativePath)
            }
            files[relativePath] = url
        }
        return SnapshotEntries(files: files, directories: directories)
    }

    private static func parentDirectories(of path: String) -> [String] {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return [] }
        return (1 ..< components.count).map { components.prefix($0).joined(separator: "/") }
    }

    private static func relativePath(of url: URL, below rootPath: String) throws -> String {
        let path = url.standardizedFileURL.path
        let prefix = rootPath + "/"
        guard path.hasPrefix(prefix) else {
            throw GemmaModelVerificationError.invalidRelativePath(path)
        }
        let relativePath = String(path.dropFirst(prefix.count))
        try GemmaModelManifest.validateRelativePath(relativePath)
        return relativePath
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readManifest(at url: URL, relativePath: String) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw GemmaModelVerificationError.manifestFileMissing(relativePath)
        }
        guard let type = attributes[.type] as? FileAttributeType else {
            throw GemmaModelVerificationError.unsupportedDirectoryEntry(relativePath)
        }
        if type == .typeSymbolicLink {
            throw GemmaModelVerificationError.symbolicLinkNotAllowed(relativePath)
        }
        guard type == .typeRegular else {
            throw GemmaModelVerificationError.unsupportedDirectoryEntry(relativePath)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GemmaModelVerificationError.manifestFileMissing(relativePath)
        }
        defer { try? handle.close() }

        let maximumReadCount = GemmaModelManifest.maximumManifestByteCount + 1
        let data: Data
        do {
            data = try handle.read(upToCount: maximumReadCount) ?? Data()
        } catch {
            throw GemmaModelVerificationError.manifestFileMissing(relativePath)
        }
        guard data.count <= GemmaModelManifest.maximumManifestByteCount else {
            throw GemmaModelVerificationError.manifestTooLarge(
                limit: GemmaModelManifest.maximumManifestByteCount,
                actualAtLeast: data.count
            )
        }
        return data
    }

    private static func sha256(of url: URL, path: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GemmaModelVerificationError.unreadableFile(path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw GemmaModelVerificationError.unreadableFile(path)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct SnapshotEntries {
        let files: [String: URL]
        let directories: Set<String>
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }
}

/// A locally verified model snapshot that must be checked again immediately before MLX loads it.
///
/// The root path is intentionally not exposed as a stored public property.
/// A factory can obtain it only by calling `revalidate()`, which repeats every manifest and file check.
public struct VerifiedGemmaModel: Sendable, Equatable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String

    private let rootDirectory: URL
    private let requirements: GemmaModelRequirements

    init(rootDirectory: URL, requirements: GemmaModelRequirements) {
        self.rootDirectory = rootDirectory
        self.requirements = requirements
        modelIdentifier = requirements.modelIdentifier
        checkpointRevision = requirements.checkpointRevision
        adapterRevision = requirements.adapterRevision
        licenseIdentifier = requirements.licenseIdentifier
        manifestSHA256 = requirements.expectedManifestSHA256
    }

    /// Rechecks the immutable snapshot before a model-loading closure obtains its root directory.
    public func revalidate() throws -> URL {
        try GemmaModelVerifier(requirements: requirements).verifiedRoot(directory: rootDirectory)
    }
}
