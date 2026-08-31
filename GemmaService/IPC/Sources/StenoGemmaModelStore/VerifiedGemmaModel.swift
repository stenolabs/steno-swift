import CryptoKit
import Darwin
import Foundation

/// A path-free identity used to bind verification to a directory already held by an importer.
public struct GemmaModelRootIdentity: Sendable, Equatable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}

/// Verifies installed Gemma trees without downloading, resolving, or loading a model.
public struct GemmaModelVerifier: Sendable {
    public let requirements: GemmaModelRequirements

    public init(requirements: GemmaModelRequirements) {
        self.requirements = requirements
    }

    /// Verifies a complete read-only snapshot.
    ///
    /// Importers can pass the identity obtained from their retained staging or destination
    /// descriptor. Verification then fails unless the path still names that exact inode.
    public func verify(
        directory: URL,
        expectedRootIdentity: GemmaModelRootIdentity? = nil,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VerifiedGemmaModel {
        let result = try verifiedRoot(
            directory: directory,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck
        )
        return VerifiedGemmaModel(
            rootDirectory: result.url,
            rootIdentity: result.identity,
            requirements: requirements
        )
    }

    private func verifiedRoot(
        directory: URL,
        expectedRootIdentity: GemmaModelRootIdentity?,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> VerifiedRoot {
        try cancellationCheck()
        let root = directory.standardizedFileURL
        let descriptor = try Self.openRoot(root)
        defer { _ = Darwin.close(descriptor) }

        let initialStatus = try Self.status(of: descriptor, path: ".")
        try Self.validateDirectory(initialStatus, path: ".")
        let rootIdentity = Self.identity(of: initialStatus)
        guard expectedRootIdentity == nil || expectedRootIdentity == rootIdentity else {
            throw GemmaModelVerificationError.rootIdentityMismatch
        }
        try Self.requirePath(root, names: initialStatus, path: ".")

        var scan = SnapshotScan()
        try Self.scanDirectory(
            descriptor,
            relativePrefix: "",
            manifestPath: requirements.manifestFileName,
            cancellationCheck: cancellationCheck,
            into: &scan
        )

        guard let manifestFile = scan.files[requirements.manifestFileName] else {
            throw GemmaModelVerificationError.manifestFileMissing(requirements.manifestFileName)
        }
        guard manifestFile.size <= Int64(GemmaModelManifest.maximumManifestByteCount),
              let manifestData = manifestFile.capturedData,
              manifestData.count <= GemmaModelManifest.maximumManifestByteCount
        else {
            throw GemmaModelVerificationError.manifestTooLarge(
                limit: GemmaModelManifest.maximumManifestByteCount,
                actualAtLeast: Int(min(manifestFile.size, Int64(Int.max)))
            )
        }
        guard manifestFile.sha256 == requirements.expectedManifestSHA256 else {
            throw GemmaModelVerificationError.manifestDigestMismatch(
                expected: requirements.expectedManifestSHA256,
                actual: manifestFile.sha256
            )
        }

        let manifest: GemmaModelManifest
        do {
            manifest = try JSONDecoder().decode(GemmaModelManifest.self, from: manifestData)
        } catch {
            throw GemmaModelVerificationError.malformedManifest
        }
        try manifest.validate(against: requirements)

        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.relativePath, $0)
        })
        let expectedPaths = Set(expectedFiles.keys).union([requirements.manifestFileName])
        let expectedDirectories = Set(
            expectedFiles.keys.flatMap(GemmaModelManifest.parentDirectories(of:))
                + GemmaModelManifest.parentDirectories(of: requirements.manifestFileName)
        )

        for path in scan.files.keys.sorted() where !expectedPaths.contains(path) {
            throw GemmaModelVerificationError.unexpectedFile(path)
        }
        for path in scan.directories.sorted() where !expectedDirectories.contains(path) {
            throw GemmaModelVerificationError.unexpectedDirectory(path)
        }
        for path in expectedFiles.keys.sorted() where scan.files[path] == nil {
            throw GemmaModelVerificationError.missingFile(path)
        }

        for path in expectedFiles.keys.sorted() {
            guard let expected = expectedFiles[path], let actual = scan.files[path] else {
                throw GemmaModelVerificationError.missingFile(path)
            }
            guard actual.size == expected.size else {
                throw GemmaModelVerificationError.fileSizeMismatch(
                    path: path,
                    expected: expected.size,
                    actual: actual.size
                )
            }
            guard actual.sha256 == expected.sha256 else {
                throw GemmaModelVerificationError.fileHashMismatch(
                    path: path,
                    expected: expected.sha256,
                    actual: actual.sha256
                )
            }
        }

        try Self.validateSafetensorsIndex(scan.files, expectedFiles: expectedFiles)
        try cancellationCheck()

        let finalStatus = try Self.status(of: descriptor, path: ".")
        guard Self.sameStableState(initialStatus, finalStatus) else {
            throw GemmaModelVerificationError.entryChanged(".")
        }
        try Self.requirePath(root, names: finalStatus, path: ".")

        return VerifiedRoot(url: root, identity: rootIdentity)
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        var pathStatus = stat()
        let lstatResult = root.path.withCString { Darwin.lstat($0, &pathStatus) }
        if lstatResult == 0, pathStatus.st_mode & S_IFMT == S_IFLNK {
            throw GemmaModelVerificationError.symbolicLinkNotAllowed(".")
        }

        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw GemmaModelVerificationError.rootIsNotDirectory
        }
        return descriptor
    }

    private static func scanDirectory(
        _ directoryDescriptor: Int32,
        relativePrefix: String,
        manifestPath: String,
        cancellationCheck: @Sendable () throws -> Void,
        into scan: inout SnapshotScan
    ) throws {
        let enumerationDescriptor = Darwin.openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let stream = Darwin.fdopendir(enumerationDescriptor)
        else {
            if enumerationDescriptor >= 0 { _ = Darwin.close(enumerationDescriptor) }
            throw GemmaModelVerificationError.unreadableFile(
                relativePrefix.isEmpty ? "." : relativePrefix
            )
        }
        defer { _ = Darwin.closedir(stream) }

        while true {
            try cancellationCheck()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else {
                    throw GemmaModelVerificationError.unreadableFile(
                        relativePrefix.isEmpty ? "." : relativePrefix
                    )
                }
                break
            }

            guard let name = directoryEntryName(entry) else {
                throw GemmaModelVerificationError.unsupportedDirectoryEntry("<non-UTF8>")
            }
            if name == "." || name == ".." { continue }

            let path = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            try GemmaModelManifest.validateRelativePath(path)
            scan.entryCount += 1
            guard scan.entryCount <= GemmaModelManifest.maximumFileCount
                    * (GemmaModelManifest.maximumPathDepth + 1) + 1
            else {
                throw GemmaModelVerificationError.tooManyFiles(
                    limit: GemmaModelManifest.maximumFileCount,
                    actual: scan.entryCount
                )
            }

            var before = stat()
            let statResult = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                throw GemmaModelVerificationError.entryChanged(path)
            }

            switch before.st_mode & S_IFMT {
            case S_IFLNK:
                throw GemmaModelVerificationError.symbolicLinkNotAllowed(path)
            case S_IFDIR:
                try validateDirectory(before, path: path)
                let child = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw GemmaModelVerificationError.entryChanged(path)
                }
                do {
                    let opened = try status(of: child, path: path)
                    guard sameStableState(before, opened) else {
                        throw GemmaModelVerificationError.entryChanged(path)
                    }
                    scan.directories.insert(path)
                    guard scan.directories.count <= GemmaModelManifest.maximumDirectoryCount else {
                        throw GemmaModelVerificationError.tooManyDirectories(
                            limit: GemmaModelManifest.maximumDirectoryCount,
                            actual: scan.directories.count
                        )
                    }
                    try scanDirectory(
                        child,
                        relativePrefix: path,
                        manifestPath: manifestPath,
                        cancellationCheck: cancellationCheck,
                        into: &scan
                    )
                    let after = try status(of: child, path: path)
                    var namedAfter = stat()
                    let namedResult = name.withCString {
                        Darwin.fstatat(
                            directoryDescriptor,
                            $0,
                            &namedAfter,
                            AT_SYMLINK_NOFOLLOW
                        )
                    }
                    guard namedResult == 0,
                          sameStableState(opened, after),
                          sameStableState(opened, namedAfter)
                    else {
                        throw GemmaModelVerificationError.entryChanged(path)
                    }
                } catch {
                    _ = Darwin.close(child)
                    throw error
                }
                _ = Darwin.close(child)
            case S_IFREG:
                try validateFile(before, path: path)
                scan.fileCount += 1
                guard scan.fileCount <= GemmaModelManifest.maximumFileCount + 1 else {
                    throw GemmaModelVerificationError.tooManyFiles(
                        limit: GemmaModelManifest.maximumFileCount,
                        actual: scan.fileCount
                    )
                }
                let captureLimit: Int? = if path == manifestPath
                    || path == "model.safetensors.index.json"
                {
                    GemmaModelManifest.maximumManifestByteCount + 1
                } else {
                    nil
                }
                scan.files[path] = try scanFile(
                    directoryDescriptor: directoryDescriptor,
                    name: name,
                    path: path,
                    before: before,
                    captureLimit: captureLimit,
                    cancellationCheck: cancellationCheck
                )
            default:
                throw GemmaModelVerificationError.unsupportedDirectoryEntry(path)
            }
        }
    }

    private static func scanFile(
        directoryDescriptor: Int32,
        name: String,
        path: String,
        before: stat,
        captureLimit: Int?,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> ScannedFile {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
        defer { _ = Darwin.close(descriptor) }

        let opened = try status(of: descriptor, path: path)
        guard sameStableState(before, opened) else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
        try validateFile(opened, path: path)

        var hasher = SHA256()
        var captured = captureLimit == nil ? nil : Data()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try cancellationCheck()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                throw GemmaModelVerificationError.unreadableFile(path)
            }
            if count == 0 { break }
            total += Int64(count)
            let chunk = Data(buffer[0 ..< count])
            hasher.update(data: chunk)
            if let captureLimit, captured!.count < captureLimit {
                captured!.append(chunk.prefix(captureLimit - captured!.count))
            }
        }

        let after = try status(of: descriptor, path: path)
        var namedAfter = stat()
        let namedResult = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &namedAfter, AT_SYMLINK_NOFOLLOW)
        }
        guard namedResult == 0,
              sameStableState(opened, after),
              sameStableState(opened, namedAfter),
              total == opened.st_size
        else {
            throw GemmaModelVerificationError.entryChanged(path)
        }

        return ScannedFile(
            size: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            capturedData: captured
        )
    }

    private static func validateSafetensorsIndex(
        _ actualFiles: [String: ScannedFile],
        expectedFiles: [String: GemmaModelManifest.GemmaModelFile]
    ) throws {
        let indexPath = "model.safetensors.index.json"
        guard let expectedIndex = expectedFiles[indexPath] else { return }
        guard expectedIndex.size <= Int64(GemmaModelManifest.maximumManifestByteCount),
              let actualIndex = actualFiles[indexPath],
              let data = actualIndex.capturedData,
              Int64(data.count) == expectedIndex.size,
              actualIndex.sha256 == expectedIndex.sha256,
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

    private static func validateDirectory(_ status: stat, path: String) throws {
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw GemmaModelVerificationError.unsupportedDirectoryEntry(path)
        }
        try validateOwnerAndMode(status, path: path, expectedMode: 0o500)
    }

    private static func validateFile(_ status: stat, path: String) throws {
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw GemmaModelVerificationError.unsupportedDirectoryEntry(path)
        }
        try validateOwnerAndMode(status, path: path, expectedMode: 0o400)
        guard status.st_nlink == 1 else {
            throw GemmaModelVerificationError.hardLinkNotAllowed(path)
        }
    }

    private static func validateOwnerAndMode(
        _ status: stat,
        path: String,
        expectedMode: UInt16
    ) throws {
        guard status.st_uid == geteuid() else {
            throw GemmaModelVerificationError.unsafeOwnership(path)
        }
        let actualMode = UInt16(status.st_mode & 0o7777)
        guard actualMode == expectedMode else {
            throw GemmaModelVerificationError.unsafePermissions(
                path: path,
                expected: expectedMode,
                actual: actualMode
            )
        }
    }

    private static func status(of descriptor: Int32, path: String) throws -> stat {
        var result = stat()
        guard Darwin.fstat(descriptor, &result) == 0 else {
            throw GemmaModelVerificationError.unreadableFile(path)
        }
        return result
    }

    private static func requirePath(_ url: URL, names expected: stat, path: String) throws {
        var named = stat()
        let result = url.path.withCString { Darwin.lstat($0, &named) }
        guard result == 0, sameStableState(expected, named) else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
    }

    private static func identity(of status: stat) -> GemmaModelRootIdentity {
        GemmaModelRootIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino)
        )
    }

    private static func sameStableState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(validatingCString: $0)
            }
        }
    }

    private struct VerifiedRoot {
        let url: URL
        let identity: GemmaModelRootIdentity
    }

    private struct SnapshotScan {
        var files: [String: ScannedFile] = [:]
        var directories = Set<String>()
        var fileCount = 0
        var entryCount = 0
    }

    private struct ScannedFile {
        let size: Int64
        let sha256: String
        let capturedData: Data?
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }
}

/// A verified model capability with path-free public provenance.
///
/// The root remains private. `revalidate()` returns it only after checking the same directory
/// identity and every manifest entry again immediately before a model-loading operation.
public struct VerifiedGemmaModel: Sendable, Equatable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String
    public let rootIdentity: GemmaModelRootIdentity

    private let rootDirectory: URL
    private let requirements: GemmaModelRequirements

    init(
        rootDirectory: URL,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements
    ) {
        self.rootDirectory = rootDirectory
        self.rootIdentity = rootIdentity
        self.requirements = requirements
        modelIdentifier = requirements.modelIdentifier
        checkpointRevision = requirements.checkpointRevision
        adapterRevision = requirements.adapterRevision
        licenseIdentifier = requirements.licenseIdentifier
        manifestSHA256 = requirements.expectedManifestSHA256
    }

    public func revalidate() throws -> URL {
        try GemmaModelVerifier(requirements: requirements)
            .verify(directory: rootDirectory, expectedRootIdentity: rootIdentity)
            .rootDirectory
    }
}
