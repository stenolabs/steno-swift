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

struct GemmaModelVerificationHooks: Sendable {
    var didCompleteMetadataPreflight: @Sendable () throws -> Void = {}
    var beforeReadingModelContent: @Sendable (String) throws -> Void = { _ in }
    var beforeFinalMetadataPass: @Sendable () throws -> Void = {}
    var beforeCompletingFinalMetadataPass: @Sendable () throws -> Void = {}
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
        try verify(
            directory: directory,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck,
            hooks: GemmaModelVerificationHooks()
        )
    }

    func verify(
        directory: URL,
        expectedRootIdentity: GemmaModelRootIdentity? = nil,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() },
        hooks: GemmaModelVerificationHooks
    ) throws -> VerifiedGemmaModel {
        try cancellationCheck()
        let root = directory.standardizedFileURL
        let descriptor = try Self.openRoot(root)
        defer { _ = Darwin.close(descriptor) }

        let result = try verifiedRoot(
            descriptor: descriptor,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck,
            hooks: hooks
        )
        try Self.requirePath(root, names: result.status, path: ".")
        return VerifiedGemmaModel(
            rootDirectory: root,
            rootIdentity: result.identity,
            requirements: requirements
        )
    }

    /// Consumes and verifies an already-open directory descriptor.
    ///
    /// Ownership transfers at entry. The descriptor is closed on every failure and is retained by
    /// the returned capability on success. Verification never resolves or reopens a filesystem path.
    public func verify(
        adoptingDirectoryDescriptor descriptor: Int32,
        expectedRootIdentity: GemmaModelRootIdentity? = nil,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VerifiedGemmaModelDirectory {
        try verify(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck,
            hooks: GemmaModelVerificationHooks()
        )
    }

    func verify(
        adoptingDirectoryDescriptor descriptor: Int32,
        expectedRootIdentity: GemmaModelRootIdentity? = nil,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() },
        hooks: GemmaModelVerificationHooks
    ) throws -> VerifiedGemmaModelDirectory {
        var ownsDescriptor = descriptor >= 0
        defer {
            if ownsDescriptor {
                _ = Darwin.close(descriptor)
            }
        }

        try Self.prepareAdoptedRootDescriptor(descriptor)
        let result = try verifiedRoot(
            descriptor: descriptor,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck,
            hooks: hooks
        )
        let capability = VerifiedGemmaModelDirectory(
            fileDescriptor: descriptor,
            rootIdentity: result.identity,
            requirements: requirements
        )
        ownsDescriptor = false
        return capability
    }

    fileprivate func verifiedRoot(
        descriptor: Int32,
        expectedRootIdentity: GemmaModelRootIdentity?,
        cancellationCheck: @Sendable () throws -> Void,
        hooks: GemmaModelVerificationHooks = GemmaModelVerificationHooks()
    ) throws -> VerifiedDescriptorRoot {
        try cancellationCheck()

        let initialStatus = try Self.status(of: descriptor, path: ".")
        try Self.validateDirectory(initialStatus, path: ".")
        let rootIdentity = Self.identity(of: initialStatus)
        guard expectedRootIdentity == nil || expectedRootIdentity == rootIdentity else {
            throw GemmaModelVerificationError.rootIdentityMismatch
        }

        let manifestRead = try Self.readPinnedManifest(
            from: descriptor,
            manifestPath: requirements.manifestFileName,
            expectedSHA256: requirements.expectedManifestSHA256,
            cancellationCheck: cancellationCheck
        )
        let manifest = try GemmaModelManifest.decode(from: manifestRead.data)
        try manifest.validate(against: requirements)

        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.relativePath, $0)
        })
        let expectedDirectories = Set(
            expectedFiles.keys.flatMap(GemmaModelManifest.parentDirectories(of:))
                + GemmaModelManifest.parentDirectories(of: requirements.manifestFileName)
        )
        let expectedTree = ExpectedTree(
            manifestPath: requirements.manifestFileName,
            manifestStatus: manifestRead.status,
            files: expectedFiles,
            directories: expectedDirectories,
            expectedFilePaths: Set(expectedFiles.keys).union([requirements.manifestFileName])
        )
        let snapshot = try Self.captureMetadataSnapshot(
            descriptor,
            initialRootStatus: initialStatus,
            expectedTree: expectedTree,
            expectedSnapshot: nil,
            cancellationCheck: cancellationCheck,
            beforeRootRevalidation: {}
        )
        try hooks.didCompleteMetadataPreflight()

        let indexData = try Self.verifyExpectedContents(
            from: descriptor,
            expectedTree: expectedTree,
            snapshot: snapshot,
            cancellationCheck: cancellationCheck,
            beforeReadingModelContent: hooks.beforeReadingModelContent
        )
        try Self.validateSafetensorsIndex(indexData, expectedFiles: expectedFiles)
        try cancellationCheck()
        try hooks.beforeFinalMetadataPass()
        let finalSnapshot = try Self.captureMetadataSnapshot(
            descriptor,
            initialRootStatus: initialStatus,
            expectedTree: expectedTree,
            expectedSnapshot: snapshot,
            cancellationCheck: cancellationCheck,
            beforeRootRevalidation: hooks.beforeCompletingFinalMetadataPass
        )

        return VerifiedDescriptorRoot(identity: rootIdentity, status: finalSnapshot.rootStatus)
    }

    fileprivate func makeActivationAssets(
        adoptingDirectoryDescriptor descriptor: Int32,
        expectedRootIdentity: GemmaModelRootIdentity,
        limits: VerifiedGemmaModelActivationLimits,
        cancellationCheck: @Sendable () throws -> Void,
        beforeOpeningModelFile: @Sendable (String) throws -> Void = { _ in },
        ownedDescriptorCloser: @escaping @Sendable (Int32) -> Void = {
            _ = Darwin.close($0)
        }
    ) throws -> VerifiedGemmaModelActivationAssets {
        var ownsDescriptor = descriptor >= 0
        defer {
            if ownsDescriptor {
                ownedDescriptorCloser(descriptor)
            }
        }

        let initialRoot = try verifiedRoot(
            descriptor: descriptor,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck
        )
        let manifestRead = try Self.openVerifiedRegularFile(
            from: descriptor,
            relativePath: requirements.manifestFileName,
            openedDescriptorCloser: ownedDescriptorCloser
        )
        defer { ownedDescriptorCloser(manifestRead.descriptor) }
        guard manifestRead.status.st_size <= Int64(GemmaModelManifest.maximumManifestByteCount) else {
            throw GemmaModelVerificationError.manifestTooLarge(
                limit: GemmaModelManifest.maximumManifestByteCount,
                actualAtLeast: Int(manifestRead.status.st_size)
            )
        }
        let manifestData = try Self.readVerifiedData(
            descriptor: manifestRead.descriptor,
            expectedStatus: manifestRead.status,
            path: requirements.manifestFileName,
            expectedSHA256: requirements.expectedManifestSHA256,
            maximumBytes: Int(manifestRead.status.st_size),
            cancellationCheck: cancellationCheck
        )
        let manifest = try GemmaModelManifest.decode(from: manifestData)
        try manifest.validate(against: requirements)

        var smallFiles: [String: Data] = [:]
        var smallTotal = 0
        var bindings: [GemmaActivationFileBinding] = [
            .init(
                relativePath: requirements.manifestFileName,
                expectedStatus: manifestRead.status,
                descriptor: nil,
                expectedSHA256: requirements.expectedManifestSHA256
            ),
        ]
        try limits.recordSmallFile(
            path: requirements.manifestFileName,
            size: manifestData.count,
            total: &smallTotal
        )
        smallFiles[requirements.manifestFileName] = manifestData

        var shardDescriptors: [String: Int32] = [:]
        var ownsShardDescriptors = true
        defer {
            if ownsShardDescriptors {
                for retained in shardDescriptors.values { ownedDescriptorCloser(retained) }
            }
        }
        var shardTotal: Int64 = 0
        for file in manifest.files.sorted(by: { $0.relativePath < $1.relativePath }) {
            try cancellationCheck()
            try beforeOpeningModelFile(file.relativePath)
            let opened = try Self.openVerifiedRegularFile(
                from: descriptor,
                relativePath: file.relativePath,
                openedDescriptorCloser: ownedDescriptorCloser
            )
            do {
                guard opened.status.st_size == file.size else {
                    throw GemmaModelVerificationError.fileSizeMismatch(
                        path: file.relativePath,
                        expected: file.size,
                        actual: opened.status.st_size
                    )
                }
                if GemmaModelManifest.isSafetensorsFile(file.relativePath) {
                    try limits.recordSafetensorsFile(
                        path: file.relativePath,
                        size: file.size,
                        total: &shardTotal,
                        count: shardDescriptors.count
                    )
                    _ = try Self.readVerifiedData(
                        descriptor: opened.descriptor,
                        expectedStatus: opened.status,
                        path: file.relativePath,
                        expectedSHA256: file.sha256,
                        maximumBytes: 0,
                        cancellationCheck: cancellationCheck,
                        retainData: false
                    )
                    shardDescriptors[file.relativePath] = opened.descriptor
                    bindings.append(.init(
                        relativePath: file.relativePath,
                        expectedStatus: opened.status,
                        descriptor: opened.descriptor,
                        expectedSHA256: file.sha256
                    ))
                } else {
                    let size = try Self.checkedInt(file.size, path: file.relativePath)
                    try limits.recordSmallFile(path: file.relativePath, size: size, total: &smallTotal)
                    let data = try Self.readVerifiedData(
                        descriptor: opened.descriptor,
                        expectedStatus: opened.status,
                        path: file.relativePath,
                        expectedSHA256: file.sha256,
                        maximumBytes: size,
                        cancellationCheck: cancellationCheck
                    )
                    smallFiles[file.relativePath] = data
                    bindings.append(.init(
                        relativePath: file.relativePath,
                        expectedStatus: opened.status,
                        descriptor: nil,
                        expectedSHA256: file.sha256
                    ))
                    ownedDescriptorCloser(opened.descriptor)
                }
            } catch {
                if shardDescriptors[file.relativePath] != opened.descriptor {
                    ownedDescriptorCloser(opened.descriptor)
                }
                throw error
            }
        }

        let finalRoot = try verifiedRoot(
            descriptor: descriptor,
            expectedRootIdentity: expectedRootIdentity,
            cancellationCheck: cancellationCheck
        )
        guard Self.sameStableState(initialRoot.status, finalRoot.status) else {
            throw GemmaModelVerificationError.entryChanged(".")
        }
        let assets = VerifiedGemmaModelActivationAssets(
            rootDescriptor: descriptor,
            rootStatus: initialRoot.status,
            rootIdentity: expectedRootIdentity,
            requirements: requirements,
            smallFiles: smallFiles,
            bindings: bindings,
            shardDescriptors: shardDescriptors,
            ownedDescriptorCloser: ownedDescriptorCloser
        )
        ownsShardDescriptors = false
        ownsDescriptor = false
        return assets
    }

    fileprivate static func revalidateActivationBindings(
        rootDescriptor: Int32,
        rootStatus: stat,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements,
        bindings: [GemmaActivationFileBinding],
        cancellationCheck: @Sendable () throws -> Void
    ) throws {
        let verifiedRoot = try GemmaModelVerifier(requirements: requirements).verifiedRoot(
            descriptor: rootDescriptor,
            expectedRootIdentity: rootIdentity,
            cancellationCheck: cancellationCheck
        )
        for binding in bindings {
            try cancellationCheck()
            if let descriptor = binding.descriptor {
                let descriptorStatus = try status(of: descriptor, path: binding.relativePath)
                guard sameStableState(binding.expectedStatus, descriptorStatus) else {
                    throw GemmaModelVerificationError.entryChanged(binding.relativePath)
                }
            }
            let named = try openVerifiedRegularFile(
                from: rootDescriptor,
                relativePath: binding.relativePath
            )
            defer { _ = Darwin.close(named.descriptor) }
            guard sameStableState(binding.expectedStatus, named.status) else {
                throw GemmaModelVerificationError.entryChanged(binding.relativePath)
            }
        }
        guard sameStableState(rootStatus, verifiedRoot.status) else {
            throw GemmaModelVerificationError.entryChanged(".")
        }
    }

    private static func openVerifiedRegularFile(
        from rootDescriptor: Int32,
        relativePath: String,
        missingFileError: GemmaModelVerificationError? = nil,
        // This closer owns only the leaf file descriptor returned to the caller or rejected after
        // it opens. Directory-walking duplicates stay private to this helper and close directly.
        openedDescriptorCloser: @Sendable (Int32) -> Void = {
            _ = Darwin.close($0)
        }
    ) throws -> OpenedActivationFile {
        try GemmaModelManifest.validateRelativePath(relativePath)
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw GemmaModelVerificationError.invalidRelativePath(relativePath)
        }
        let initialDirectory = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard initialDirectory >= 0 else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
        var directoryDescriptor = initialDirectory
        do {
            for component in components.dropLast() {
                var namedBefore = stat()
                let namedResult = component.withCString {
                    Darwin.fstatat(directoryDescriptor, $0, &namedBefore, AT_SYMLINK_NOFOLLOW)
                }
                let namedErrno = errno
                guard namedResult == 0 else {
                    if namedErrno == ENOENT, let missingFileError {
                        throw missingFileError
                    }
                    throw GemmaModelVerificationError.entryChanged(relativePath)
                }
                if namedBefore.st_mode & S_IFMT == S_IFLNK {
                    throw GemmaModelVerificationError.symbolicLinkNotAllowed(relativePath)
                }
                try validateDirectory(namedBefore, path: relativePath)
                let child = component.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw GemmaModelVerificationError.entryChanged(relativePath)
                }
                let opened: stat
                do {
                    opened = try status(of: child, path: relativePath)
                    guard sameStableState(namedBefore, opened) else {
                        throw GemmaModelVerificationError.entryChanged(relativePath)
                    }
                    try validateDirectory(opened, path: relativePath)
                } catch {
                    _ = Darwin.close(child)
                    throw error
                }
                _ = Darwin.close(directoryDescriptor)
                directoryDescriptor = child
            }
            var namedBefore = stat()
            let namedResult = fileName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &namedBefore, AT_SYMLINK_NOFOLLOW)
            }
            let namedErrno = errno
            guard namedResult == 0 else {
                if namedErrno == ENOENT, let missingFileError {
                    throw missingFileError
                }
                throw GemmaModelVerificationError.entryChanged(relativePath)
            }
            if namedBefore.st_mode & S_IFMT == S_IFLNK {
                throw GemmaModelVerificationError.symbolicLinkNotAllowed(relativePath)
            }
            let fileDescriptor = fileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else {
                throw GemmaModelVerificationError.entryChanged(relativePath)
            }
            var ownsFileDescriptor = true
            defer {
                if ownsFileDescriptor {
                    openedDescriptorCloser(fileDescriptor)
                }
            }
            let opened = try status(of: fileDescriptor, path: relativePath)
            guard sameStableState(namedBefore, opened) else {
                throw GemmaModelVerificationError.entryChanged(relativePath)
            }
            try validateFile(opened, path: relativePath)
            ownsFileDescriptor = false
            _ = Darwin.close(directoryDescriptor)
            return OpenedActivationFile(descriptor: fileDescriptor, status: opened)
        } catch {
            _ = Darwin.close(directoryDescriptor)
            throw error
        }
    }

    static func probeActivationFileForTesting(
        from rootDescriptor: Int32,
        relativePath: String,
        openedDescriptorCloser: @Sendable (Int32) -> Void
    ) throws {
        let opened = try openVerifiedRegularFile(
            from: rootDescriptor,
            relativePath: relativePath,
            openedDescriptorCloser: openedDescriptorCloser
        )
        openedDescriptorCloser(opened.descriptor)
    }

    fileprivate static func readVerifiedData(
        descriptor: Int32,
        expectedStatus: stat,
        path: String,
        expectedSHA256: String,
        maximumBytes: Int,
        cancellationCheck: @Sendable () throws -> Void,
        retainData: Bool = true
    ) throws -> Data {
        guard expectedStatus.st_size >= 0 else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
        let expectedSize = try checkedInt(expectedStatus.st_size, path: path)
        if retainData, expectedSize > maximumBytes {
            throw GemmaModelVerificationError.activationSmallFileTooLarge(
                path: path,
                limit: maximumBytes,
                actual: expectedSize
            )
        }
        try cancellationCheck()
        var data = retainData ? Data(capacity: expectedSize) : Data()
        var hasher = SHA256()
        var offset: off_t = 0
        var remaining = expectedSize
        var buffer = [UInt8](repeating: 0, count: min(1 << 20, max(1, expectedSize)))
        while remaining > 0 {
            try cancellationCheck()
            let request = min(remaining, buffer.count)
            let count: Int
            while true {
                let result = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(descriptor, bytes.baseAddress, request, offset)
                }
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else {
                    throw GemmaModelVerificationError.unreadableFile(path)
                }
                count = result
                break
            }
            guard count > 0 else {
                throw GemmaModelVerificationError.entryChanged(path)
            }
            let chunk = Data(buffer[0 ..< count])
            hasher.update(data: chunk)
            if retainData { data.append(chunk) }
            remaining -= count
            offset += off_t(count)
        }
        var probe: UInt8 = 0
        while true {
            let result = Darwin.pread(descriptor, &probe, 1, offset)
            if result < 0, errno == EINTR { continue }
            guard result == 0 else {
                throw GemmaModelVerificationError.entryChanged(path)
            }
            break
        }
        let finalStatus = try status(of: descriptor, path: path)
        guard sameStableState(expectedStatus, finalStatus) else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
        let actualSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualSHA256 == expectedSHA256 else {
            throw GemmaModelVerificationError.fileHashMismatch(
                path: path,
                expected: expectedSHA256,
                actual: actualSHA256
            )
        }
        return data
    }

    private static func checkedInt(_ value: Int64, path: String) throws -> Int {
        guard value >= 0, value <= Int64(Int.max) else {
            throw GemmaModelVerificationError.entryChanged(path)
        }
        return Int(value)
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

    private static func prepareAdoptedRootDescriptor(_ descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
        let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0 else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
        guard statusFlags & O_ACCMODE == O_RDONLY else {
            throw GemmaModelVerificationError.rootDescriptorNotReadOnly
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw GemmaModelVerificationError.rootIsNotDirectory
        }
    }

    private static func readPinnedManifest(
        from rootDescriptor: Int32,
        manifestPath: String,
        expectedSHA256: String,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> ManifestRead {
        let opened = try openVerifiedRegularFile(
            from: rootDescriptor,
            relativePath: manifestPath,
            missingFileError: .manifestFileMissing(manifestPath)
        )
        defer { _ = Darwin.close(opened.descriptor) }

        guard opened.status.st_size >= 0 else {
            throw GemmaModelVerificationError.entryChanged(manifestPath)
        }
        guard opened.status.st_size <= Int64(GemmaModelManifest.maximumManifestByteCount) else {
            throw GemmaModelVerificationError.manifestTooLarge(
                limit: GemmaModelManifest.maximumManifestByteCount,
                actualAtLeast: Int(min(opened.status.st_size, Int64(Int.max)))
            )
        }

        let data: Data
        do {
            data = try readVerifiedData(
                descriptor: opened.descriptor,
                expectedStatus: opened.status,
                path: manifestPath,
                expectedSHA256: expectedSHA256,
                maximumBytes: GemmaModelManifest.maximumManifestByteCount,
                cancellationCheck: cancellationCheck
            )
        } catch GemmaModelVerificationError.fileHashMismatch(_, _, let actual) {
            throw GemmaModelVerificationError.manifestDigestMismatch(
                expected: expectedSHA256,
                actual: actual
            )
        }
        return ManifestRead(data: data, status: opened.status)
    }

    private static func captureMetadataSnapshot(
        _ rootDescriptor: Int32,
        initialRootStatus: stat,
        expectedTree: ExpectedTree,
        expectedSnapshot: MetadataSnapshot?,
        cancellationCheck: @Sendable () throws -> Void,
        beforeRootRevalidation: @Sendable () throws -> Void
    ) throws -> MetadataSnapshot {
        try cancellationCheck()
        let rootStatus = try status(of: rootDescriptor, path: ".")
        try validateDirectory(rootStatus, path: ".")
        guard sameStableState(initialRootStatus, rootStatus),
              expectedSnapshot.map({ sameStableState($0.rootStatus, rootStatus) }) ?? true
        else {
            throw GemmaModelVerificationError.entryChanged(".")
        }

        var scan = MetadataScan()
        try scanMetadataDirectory(
            rootDescriptor,
            relativePrefix: "",
            expectedTree: expectedTree,
            expectedSnapshot: expectedSnapshot,
            cancellationCheck: cancellationCheck,
            into: &scan
        )
        try requireExpectedFilesPresent(
            in: scan,
            expectedTree: expectedTree,
            isRevalidation: expectedSnapshot != nil
        )

        try beforeRootRevalidation()
        if let expectedSnapshot {
            var confirmation = MetadataScan()
            try scanMetadataDirectory(
                rootDescriptor,
                relativePrefix: "",
                expectedTree: expectedTree,
                expectedSnapshot: expectedSnapshot,
                cancellationCheck: cancellationCheck,
                into: &confirmation
            )
            try requireExpectedFilesPresent(
                in: confirmation,
                expectedTree: expectedTree,
                isRevalidation: true
            )
            scan = confirmation
        }
        let finalRootStatus = try status(of: rootDescriptor, path: ".")
        guard sameStableState(rootStatus, finalRootStatus),
              sameStableState(initialRootStatus, finalRootStatus),
              expectedSnapshot.map({ sameStableState($0.rootStatus, finalRootStatus) }) ?? true
        else {
            throw GemmaModelVerificationError.entryChanged(".")
        }

        return MetadataSnapshot(
            rootStatus: finalRootStatus,
            directoryStatuses: scan.directories,
            fileStatuses: scan.files
        )
    }

    private static func requireExpectedFilesPresent(
        in scan: MetadataScan,
        expectedTree: ExpectedTree,
        isRevalidation: Bool
    ) throws {
        for path in expectedTree.expectedFilePaths.sorted() where scan.files[path] == nil {
            if isRevalidation {
                throw GemmaModelVerificationError.entryChanged(path)
            }
            if path == expectedTree.manifestPath {
                throw GemmaModelVerificationError.manifestFileMissing(path)
            }
            throw GemmaModelVerificationError.missingFile(path)
        }
    }

    private static func scanMetadataDirectory(
        _ directoryDescriptor: Int32,
        relativePrefix: String,
        expectedTree: ExpectedTree,
        expectedSnapshot: MetadataSnapshot?,
        cancellationCheck: @Sendable () throws -> Void,
        into scan: inout MetadataScan
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
                guard expectedTree.directories.contains(path) else {
                    throw GemmaModelVerificationError.unexpectedDirectory(path)
                }
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
                    if let expected = expectedSnapshot?.directoryStatuses[path],
                       !sameStableState(expected, opened) {
                        throw GemmaModelVerificationError.entryChanged(path)
                    }
                    scan.directories[path] = opened
                    guard scan.directories.count <= GemmaModelManifest.maximumDirectoryCount else {
                        throw GemmaModelVerificationError.tooManyDirectories(
                            limit: GemmaModelManifest.maximumDirectoryCount,
                            actual: scan.directories.count
                        )
                    }
                    try scanMetadataDirectory(
                        child,
                        relativePrefix: path,
                        expectedTree: expectedTree,
                        expectedSnapshot: expectedSnapshot,
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
                guard expectedTree.expectedFilePaths.contains(path) else {
                    throw GemmaModelVerificationError.unexpectedFile(path)
                }
                try validateFile(before, path: path)
                scan.fileCount += 1
                guard scan.fileCount <= GemmaModelManifest.maximumFileCount + 1 else {
                    throw GemmaModelVerificationError.tooManyFiles(
                        limit: GemmaModelManifest.maximumFileCount,
                        actual: scan.fileCount
                    )
                }
                if let expectedSnapshot {
                    guard let expected = expectedSnapshot.fileStatuses[path],
                          sameStableState(expected, before)
                    else {
                        throw GemmaModelVerificationError.entryChanged(path)
                    }
                } else if path == expectedTree.manifestPath {
                    guard sameStableState(expectedTree.manifestStatus, before) else {
                        throw GemmaModelVerificationError.entryChanged(path)
                    }
                } else if let expected = expectedTree.files[path], before.st_size != expected.size {
                    throw GemmaModelVerificationError.fileSizeMismatch(
                        path: path,
                        expected: expected.size,
                        actual: before.st_size
                    )
                }
                scan.files[path] = before
            default:
                throw GemmaModelVerificationError.unsupportedDirectoryEntry(path)
            }
        }
    }

    private static func verifyExpectedContents(
        from rootDescriptor: Int32,
        expectedTree: ExpectedTree,
        snapshot: MetadataSnapshot,
        cancellationCheck: @Sendable () throws -> Void,
        beforeReadingModelContent: @Sendable (String) throws -> Void
    ) throws -> Data? {
        let indexPath = "model.safetensors.index.json"
        if let index = expectedTree.files[indexPath],
           index.size > Int64(GemmaModelManifest.maximumManifestByteCount) {
            throw GemmaModelVerificationError.malformedSafetensorsIndex
        }

        var indexData: Data?
        for path in expectedTree.files.keys.sorted() {
            try cancellationCheck()
            try beforeReadingModelContent(path)
            guard let expected = expectedTree.files[path],
                  let expectedStatus = snapshot.fileStatuses[path]
            else {
                throw GemmaModelVerificationError.missingFile(path)
            }
            let retainData = path == indexPath
            let data: Data
            do {
                let opened = try openVerifiedRegularFile(
                    from: rootDescriptor,
                    relativePath: path
                )
                defer { _ = Darwin.close(opened.descriptor) }
                guard sameStableState(expectedStatus, opened.status) else {
                    throw GemmaModelVerificationError.entryChanged(path)
                }
                data = try readVerifiedData(
                    descriptor: opened.descriptor,
                    expectedStatus: opened.status,
                    path: path,
                    expectedSHA256: expected.sha256,
                    maximumBytes: retainData ? GemmaModelManifest.maximumManifestByteCount : 0,
                    cancellationCheck: cancellationCheck,
                    retainData: retainData
                )
            }
            if retainData { indexData = data }
        }
        return indexData
    }

    private static func validateSafetensorsIndex(
        _ indexData: Data?,
        expectedFiles: [String: GemmaModelManifest.GemmaModelFile]
    ) throws {
        let indexPath = "model.safetensors.index.json"
        guard let expectedIndex = expectedFiles[indexPath] else { return }
        guard expectedIndex.size <= Int64(GemmaModelManifest.maximumManifestByteCount),
              let data = indexData,
              Int64(data.count) == expectedIndex.size,
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
            guard GemmaModelManifest.isSafetensorsFile(path), expectedFiles[path] != nil else {
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

    fileprivate static func status(of descriptor: Int32, path: String) throws -> stat {
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

    fileprivate static func sameStableState(_ lhs: stat, _ rhs: stat) -> Bool {
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

    fileprivate struct VerifiedDescriptorRoot {
        let identity: GemmaModelRootIdentity
        let status: stat
    }

    private struct ManifestRead {
        let data: Data
        let status: stat
    }

    private struct ExpectedTree {
        let manifestPath: String
        let manifestStatus: stat
        let files: [String: GemmaModelManifest.GemmaModelFile]
        let directories: Set<String>
        let expectedFilePaths: Set<String>
    }

    private struct MetadataSnapshot {
        let rootStatus: stat
        let directoryStatuses: [String: stat]
        let fileStatuses: [String: stat]
    }

    private struct MetadataScan {
        var files: [String: stat] = [:]
        var directories: [String: stat] = [:]
        var fileCount = 0
        var entryCount = 0
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }
}

/// An owned, descriptor-rooted capability for a Gemma root whose contents passed full verification.
///
/// This capability is deliberately neither `Codable` nor path-backed. Closing it invalidates the
/// descriptor permanently. Every borrowed operation holds the descriptor open for the complete
/// non-escaping closure, and revalidation traverses only from that retained directory descriptor.
/// The root descriptor does not freeze child-file contents after a verification pass.
public final class VerifiedGemmaModelDirectory: @unchecked Sendable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String
    public let rootIdentity: GemmaModelRootIdentity

    private let requirements: GemmaModelRequirements
    private let state: VerifiedGemmaModelDirectoryState

    fileprivate init(
        fileDescriptor: Int32,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements
    ) {
        self.rootIdentity = rootIdentity
        self.requirements = requirements
        state = VerifiedGemmaModelDirectoryState(fileDescriptor: fileDescriptor)
        modelIdentifier = requirements.modelIdentifier
        checkpointRevision = requirements.checkpointRevision
        adapterRevision = requirements.adapterRevision
        licenseIdentifier = requirements.licenseIdentifier
        manifestSHA256 = requirements.expectedManifestSHA256
    }

    deinit {
        close()
    }

    /// Permanently closes the owned directory descriptor. Repeated calls are harmless.
    public func close() {
        state.close()
    }

    /// Runs a non-escaping operation while the owned descriptor is guaranteed to remain open.
    ///
    /// The descriptor is borrowed. The closure must not close it or retain its numeric value.
    public func withBorrowedFileDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) rethrows -> Result? {
        try state.withOpenDescriptor(body)
    }

    /// Repeats full verification from the retained root descriptor without consulting a path.
    public func revalidate(
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        let didVerify: Bool? = try state.withOpenDescriptor { descriptor in
            _ = try GemmaModelVerifier(requirements: requirements).verifiedRoot(
                descriptor: descriptor,
                expectedRootIdentity: rootIdentity,
                cancellationCheck: cancellationCheck
            )
            return true
        }
        guard didVerify == true else {
            throw GemmaModelVerificationError.invalidRootDescriptor
        }
    }

    /// Transfers this directory capability into one activation capability.
    ///
    /// The directory is invalid after this call, whether creation succeeds or fails. Activation
    /// never resolves a path and has no default limits because the caller owns its memory budget.
    @_spi(StenoGemmaRuntime)
    public func consumeActivationAssets(
        limits: VerifiedGemmaModelActivationLimits,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VerifiedGemmaModelActivationAssets {
        guard let descriptor = state.takeDescriptor() else {
            throw GemmaModelVerificationError.activationAssetsUnavailable
        }
        return try GemmaModelVerifier(requirements: requirements).makeActivationAssets(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: rootIdentity,
            limits: limits,
            cancellationCheck: cancellationCheck
        )
    }

    func consumeActivationAssetsForTesting(
        limits: VerifiedGemmaModelActivationLimits,
        beforeOpeningModelFile: @escaping @Sendable (String) throws -> Void = { _ in },
        ownedDescriptorCloser: @escaping @Sendable (Int32) -> Void
    ) throws -> VerifiedGemmaModelActivationAssets {
        guard let descriptor = state.takeDescriptor() else {
            throw GemmaModelVerificationError.activationAssetsUnavailable
        }
        return try GemmaModelVerifier(requirements: requirements).makeActivationAssets(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: rootIdentity,
            limits: limits,
            cancellationCheck: { try Task.checkCancellation() },
            beforeOpeningModelFile: beforeOpeningModelFile,
            ownedDescriptorCloser: ownedDescriptorCloser
        )
    }
}

private final class VerifiedGemmaModelDirectoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func close() {
        let descriptor = lock.withLock {
            guard fileDescriptor >= 0 else { return Int32(-1) }
            defer { fileDescriptor = -1 }
            return fileDescriptor
        }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    func withOpenDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) rethrows -> Result? {
        try lock.withLock {
            guard fileDescriptor >= 0 else { return nil }
            return try body(fileDescriptor)
        }
    }

    func takeDescriptor() -> Int32? {
        lock.withLock {
            guard fileDescriptor >= 0 else { return nil }
            defer { fileDescriptor = -1 }
            return fileDescriptor
        }
    }
}

/// Explicit caller-owned bounds for converting verified model assets into activation inputs.
@_spi(StenoGemmaRuntime)
public struct VerifiedGemmaModelActivationLimits: Sendable, Equatable {
    public let maximumSmallFileByteCount: Int
    public let maximumTotalSmallFileByteCount: Int
    public let maximumSafetensorsFileCount: Int
    public let maximumSafetensorsFileByteCount: Int64
    public let maximumTotalSafetensorsByteCount: Int64

    public init(
        maximumSmallFileByteCount: Int,
        maximumTotalSmallFileByteCount: Int,
        maximumSafetensorsFileCount: Int,
        maximumSafetensorsFileByteCount: Int64,
        maximumTotalSafetensorsByteCount: Int64
    ) throws {
        guard maximumSmallFileByteCount >= 0,
              maximumTotalSmallFileByteCount >= 0,
              maximumSafetensorsFileCount >= 0,
              maximumSafetensorsFileByteCount >= 0,
              maximumTotalSafetensorsByteCount >= 0
        else {
            throw GemmaModelVerificationError.invalidActivationLimits
        }
        self.maximumSmallFileByteCount = maximumSmallFileByteCount
        self.maximumTotalSmallFileByteCount = maximumTotalSmallFileByteCount
        self.maximumSafetensorsFileCount = maximumSafetensorsFileCount
        self.maximumSafetensorsFileByteCount = maximumSafetensorsFileByteCount
        self.maximumTotalSafetensorsByteCount = maximumTotalSafetensorsByteCount
    }

    func recordSmallFile(path: String, size: Int, total: inout Int) throws {
        guard size <= maximumSmallFileByteCount else {
            throw GemmaModelVerificationError.activationSmallFileTooLarge(
                path: path,
                limit: maximumSmallFileByteCount,
                actual: size
            )
        }
        let (next, overflow) = total.addingReportingOverflow(size)
        guard !overflow, next <= maximumTotalSmallFileByteCount else {
            throw GemmaModelVerificationError.activationSmallFilesTooLarge(
                limit: maximumTotalSmallFileByteCount,
                actualAtLeast: overflow ? Int.max : next
            )
        }
        total = next
    }

    func recordSafetensorsFile(
        path: String,
        size: Int64,
        total: inout Int64,
        count: Int
    ) throws {
        guard size <= maximumSafetensorsFileByteCount else {
            throw GemmaModelVerificationError.activationSafetensorsFileTooLarge(
                path: path,
                limit: maximumSafetensorsFileByteCount,
                actual: size
            )
        }
        let (nextCount, countOverflow) = count.addingReportingOverflow(1)
        guard !countOverflow, nextCount <= maximumSafetensorsFileCount else {
            throw GemmaModelVerificationError.tooManyActivationSafetensorsFiles(
                limit: maximumSafetensorsFileCount,
                actual: countOverflow ? Int.max : nextCount
            )
        }
        let (nextTotal, sizeOverflow) = total.addingReportingOverflow(size)
        guard !sizeOverflow, nextTotal <= maximumTotalSafetensorsByteCount else {
            throw GemmaModelVerificationError.activationSafetensorsFilesTooLarge(
                limit: maximumTotalSafetensorsByteCount,
                actualAtLeast: sizeOverflow ? Int64.max : nextTotal
            )
        }
        total = nextTotal
    }
}

/// An owned, one-shot activation capability that never exposes a filesystem path or raw FD.
@_spi(StenoGemmaRuntime)
public final class VerifiedGemmaModelActivationAssets: @unchecked Sendable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String
    public let rootIdentity: GemmaModelRootIdentity

    private let state: GemmaActivationAssetsState

    fileprivate init(
        rootDescriptor: Int32,
        rootStatus: stat,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements,
        smallFiles: [String: Data],
        bindings: [GemmaActivationFileBinding],
        shardDescriptors: [String: Int32],
        ownedDescriptorCloser: @escaping @Sendable (Int32) -> Void
    ) {
        self.rootIdentity = rootIdentity
        modelIdentifier = requirements.modelIdentifier
        checkpointRevision = requirements.checkpointRevision
        adapterRevision = requirements.adapterRevision
        licenseIdentifier = requirements.licenseIdentifier
        manifestSHA256 = requirements.expectedManifestSHA256
        state = GemmaActivationAssetsState(
            rootDescriptor: rootDescriptor,
            rootStatus: rootStatus,
            rootIdentity: rootIdentity,
            requirements: requirements,
            smallFiles: smallFiles,
            bindings: bindings,
            shardDescriptors: shardDescriptors,
            ownedDescriptorCloser: ownedDescriptorCloser
        )
    }

    deinit {
        close()
    }

    /// Closes the activation capability. A close concurrent with `consume` prevents publishing a
    /// result and closes the descriptors after the callback returns and an active verification
    /// operation reaches its next cancellation checkpoint.
    public func close() {
        state.close()
    }

    func ownedDescriptorsForTesting() -> [Int32] {
        state.ownedDescriptorsForTesting()
    }

    /// Calls `body` exactly once with path-free immutable data and a one-shot shard stream.
    ///
    /// The callback result is returned only after the descriptor-rooted tree and every retained
    /// shard descriptor still match the activation snapshot. All descriptors close on every exit.
    /// The trusted runtime must publish only this returned result and no callback side effects.
    @_spi(StenoGemmaRuntime)
    public func consume<Result>(
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() },
        _ body: (BorrowedGemmaModelActivationAssets) throws -> Result
    ) throws -> Result {
        try state.consume(cancellationCheck: cancellationCheck, body)
    }
}

/// The non-Sendable value borrowed during `VerifiedGemmaModelActivationAssets.consume`.
@_spi(StenoGemmaRuntime)
public final class BorrowedGemmaModelActivationAssets {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String
    public let rootIdentity: GemmaModelRootIdentity

    private let state: BorrowedGemmaModelActivationAssetsState

    fileprivate init(
        requirements: GemmaModelRequirements,
        rootIdentity: GemmaModelRootIdentity,
        smallFiles: [String: Data],
        shards: [String: BorrowedGemmaSafetensorsFile],
        consumptionOpenCheck: @escaping @Sendable () throws -> Void
    ) {
        modelIdentifier = requirements.modelIdentifier
        checkpointRevision = requirements.checkpointRevision
        adapterRevision = requirements.adapterRevision
        licenseIdentifier = requirements.licenseIdentifier
        manifestSHA256 = requirements.expectedManifestSHA256
        self.rootIdentity = rootIdentity
        state = BorrowedGemmaModelActivationAssetsState(
            smallFiles: smallFiles,
            shards: shards,
            consumptionOpenCheck: consumptionOpenCheck
        )
    }

    public func data(forRelativePath path: String) -> Data? {
        state.data(forRelativePath: path)
    }

    public var safetensorsRelativePaths: [String] {
        state.safetensorsRelativePaths
    }

    /// Copies every manifest-bound shard exactly once and verifies its full hash before `body`.
    /// The consumer receives immutable bytes only, never a file descriptor or a filesystem path.
    @_spi(StenoGemmaRuntime)
    public func consumeSafetensorsFiles(
        cancellationCheck: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() },
        _ body: (VerifiedGemmaSafetensorsData) throws -> Void
    ) throws {
        let borrowedState = state
        let closeAwareCancellationCheck: @Sendable () throws -> Void = {
            try borrowedState.requireConsumptionOpen()
            try cancellationCheck()
            try borrowedState.requireConsumptionOpen()
        }
        let shards = try state.beginSafetensorsConsumption()
        var tensorNames: [String: String] = [:]
        for path in shards.keys.sorted() {
            try closeAwareCancellationCheck()
            guard let reader = shards[path] else {
                throw GemmaModelVerificationError.activationAssetsUnavailable
            }
            try reader.consume(cancellationCheck: closeAwareCancellationCheck) { data in
                let parsed = try SafetensorsFileParser.parse(data)
                try closeAwareCancellationCheck()
                for tensor in parsed.tensors {
                    if let firstShard = tensorNames[tensor.name] {
                        throw GemmaModelVerificationError.duplicateSafetensorsTensorName(
                            name: tensor.name,
                            firstShard: firstShard,
                            duplicateShard: path
                        )
                    }
                }
                for tensor in parsed.tensors {
                    tensorNames[tensor.name] = path
                }
                try closeAwareCancellationCheck()
                try body(VerifiedGemmaSafetensorsData(
                    relativePath: path,
                    size: reader.size,
                    data: data,
                    metadata: parsed.metadata,
                    tensors: parsed.tensors.map(VerifiedGemmaSafetensorsTensorDescriptor.init)
                ))
            }
        }
    }

    fileprivate func expire() {
        state.expire()
    }
}

/// Immutable bytes for one verified safetensors shard passed to a synchronous trusted consumer.
@_spi(StenoGemmaRuntime)
public struct VerifiedGemmaSafetensorsData: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let data: Data
    public let metadata: [String: String]
    public let tensors: [VerifiedGemmaSafetensorsTensorDescriptor]

    fileprivate init(
        relativePath: String,
        size: Int64,
        data: Data,
        metadata: [String: String],
        tensors: [VerifiedGemmaSafetensorsTensorDescriptor]
    ) {
        self.relativePath = relativePath
        self.size = size
        self.data = data
        self.metadata = metadata
        self.tensors = tensors
    }
}

/// A parsed safetensors tensor descriptor for a shard verified during activation.
@_spi(StenoGemmaRuntime)
public struct VerifiedGemmaSafetensorsTensorDescriptor: Sendable, Equatable {
    public let name: String
    public let dtype: VerifiedGemmaSafetensorsDType
    public let shape: [UInt64]

    /// Tensor bytes relative to the first payload byte after the JSON header.
    public let payloadByteRange: Range<Int>

    fileprivate init(_ tensor: SafetensorsTensor) {
        name = tensor.name
        dtype = VerifiedGemmaSafetensorsDType(tensor.dtype)
        shape = tensor.shape
        payloadByteRange = tensor.payloadByteRange
    }
}

/// Safetensors scalar types accepted by the pinned MLX adapter revision.
@_spi(StenoGemmaRuntime)
public enum VerifiedGemmaSafetensorsDType: String, CaseIterable, Sendable, Equatable {
    case float16 = "F16"
    case bfloat16 = "BF16"
    case float32 = "F32"
    case bool = "BOOL"
    case int8 = "I8"
    case int16 = "I16"
    case int32 = "I32"
    case int64 = "I64"
    case uint8 = "U8"
    case uint16 = "U16"
    case uint32 = "U32"
    case uint64 = "U64"
    case float8E4M3 = "F8_E4M3"
    case complex64 = "C64"

    fileprivate init(_ dtype: SafetensorsDType) {
        switch dtype {
        case .float16: self = .float16
        case .bfloat16: self = .bfloat16
        case .float32: self = .float32
        case .bool: self = .bool
        case .int8: self = .int8
        case .int16: self = .int16
        case .int32: self = .int32
        case .int64: self = .int64
        case .uint8: self = .uint8
        case .uint16: self = .uint16
        case .uint32: self = .uint32
        case .uint64: self = .uint64
        case .float8E4M3: self = .float8E4M3
        case .complex64: self = .complex64
        }
    }
}

/// Internal synchronous reader. It deliberately never exposes its descriptor to callers.
private final class BorrowedGemmaSafetensorsFile: @unchecked Sendable {
    let relativePath: String
    let size: Int64

    private let state: BorrowedGemmaSafetensorsFileState

    fileprivate init(
        relativePath: String,
        size: Int64,
        descriptor: Int32,
        expectedStatus: stat,
        expectedSHA256: String
    ) {
        self.relativePath = relativePath
        self.size = size
        state = BorrowedGemmaSafetensorsFileState(
            descriptor: descriptor,
            expectedStatus: expectedStatus,
            path: relativePath,
            expectedSHA256: expectedSHA256
        )
    }

    func consume(
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() },
        _ body: (Data) throws -> Void
    ) throws {
        let data = try state.read(cancellationCheck: cancellationCheck)
        try cancellationCheck()
        try body(data)
    }

    fileprivate func expire() {
        state.expire()
    }
}

fileprivate struct GemmaActivationFileBinding {
    let relativePath: String
    let expectedStatus: stat
    let descriptor: Int32?
    let expectedSHA256: String
}

private struct OpenedActivationFile {
    let descriptor: Int32
    let status: stat
}

private final class BorrowedGemmaSafetensorsFileState: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var consumed = false
    private let descriptor: Int32
    private let expectedStatus: stat
    private let path: String
    private let expectedSHA256: String

    init(
        descriptor: Int32,
        expectedStatus: stat,
        path: String,
        expectedSHA256: String
    ) {
        self.descriptor = descriptor
        self.expectedStatus = expectedStatus
        self.path = path
        self.expectedSHA256 = expectedSHA256
    }

    func read(cancellationCheck: @Sendable () throws -> Void) throws -> Data {
        try lock.withLock {
            guard valid, !consumed else {
                throw GemmaModelVerificationError.activationAssetsUnavailable
            }
            consumed = true
            return try GemmaModelVerifier.readVerifiedData(
                descriptor: descriptor,
                expectedStatus: expectedStatus,
                path: path,
                expectedSHA256: expectedSHA256,
                maximumBytes: Int.max,
                cancellationCheck: cancellationCheck
            )
        }
    }

    func expire() {
        lock.withLock { valid = false }
    }
}

private final class BorrowedGemmaModelActivationAssetsState: @unchecked Sendable {
    private let lock = NSLock()
    private let smallFiles: [String: Data]
    private let shards: [String: BorrowedGemmaSafetensorsFile]
    private let consumptionOpenCheck: @Sendable () throws -> Void
    private var valid = true
    private var consumed = false

    init(
        smallFiles: [String: Data],
        shards: [String: BorrowedGemmaSafetensorsFile],
        consumptionOpenCheck: @escaping @Sendable () throws -> Void
    ) {
        self.smallFiles = smallFiles
        self.shards = shards
        self.consumptionOpenCheck = consumptionOpenCheck
    }

    func data(forRelativePath path: String) -> Data? {
        lock.withLock {
            guard valid else { return nil }
            return smallFiles[path]
        }
    }

    var safetensorsRelativePaths: [String] {
        lock.withLock {
            guard valid else { return [] }
            return shards.keys.sorted()
        }
    }

    func beginSafetensorsConsumption() throws -> [String: BorrowedGemmaSafetensorsFile] {
        try lock.withLock {
            guard valid, !consumed else {
                throw GemmaModelVerificationError.activationAssetsUnavailable
            }
            consumed = true
            return shards
        }
    }

    func requireConsumptionOpen() throws {
        try consumptionOpenCheck()
    }

    func expire() {
        let readers: [BorrowedGemmaSafetensorsFile] = lock.withLock {
            guard valid else { return [] }
            valid = false
            return Array(shards.values)
        }
        readers.forEach { $0.expire() }
    }
}

private final class GemmaActivationAssetsState: @unchecked Sendable {
    private enum State {
        case ready(GemmaActivationResources)
        case consuming(GemmaActivationResources, closeRequested: Bool)
        case finished
    }

    private let lock = NSLock()
    private var state: State

    init(
        rootDescriptor: Int32,
        rootStatus: stat,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements,
        smallFiles: [String: Data],
        bindings: [GemmaActivationFileBinding],
        shardDescriptors: [String: Int32],
        ownedDescriptorCloser: @escaping @Sendable (Int32) -> Void
    ) {
        state = .ready(GemmaActivationResources(
            rootDescriptor: rootDescriptor,
            rootStatus: rootStatus,
            rootIdentity: rootIdentity,
            requirements: requirements,
            smallFiles: smallFiles,
            bindings: bindings,
            shardDescriptors: shardDescriptors,
            ownedDescriptorCloser: ownedDescriptorCloser
        ))
    }

    func close() {
        let detached: GemmaActivationResources? = lock.withLock {
            switch state {
            case .ready(let resources):
                state = .finished
                return resources
            case .consuming(let resources, closeRequested: false):
                state = .consuming(resources, closeRequested: true)
                return nil
            case .consuming(_, closeRequested: true), .finished:
                return nil
            }
        }
        detached?.close()
    }

    func consume<Result>(
        cancellationCheck: @Sendable () throws -> Void,
        _ body: (BorrowedGemmaModelActivationAssets) throws -> Result
    ) throws -> Result {
        let resources: GemmaActivationResources = try lock.withLock {
            guard case .ready(let ownedResources) = state else {
                throw GemmaModelVerificationError.activationAssetsUnavailable
            }
            state = .consuming(ownedResources, closeRequested: false)
            return ownedResources
        }
        let resourceIdentity = ObjectIdentifier(resources)
        var didCommit = false
        defer {
            if !didCommit {
                let detached: GemmaActivationResources? = lock.withLock {
                    guard case .consuming(let ownedResources, _) = state,
                          ownedResources === resources
                    else { return nil }
                    state = .finished
                    return ownedResources
                }
                detached?.close()
            }
        }

        try requireConsumptionOpen(
            resourceIdentity: resourceIdentity,
            cancellationCheck: cancellationCheck
        )
        let readers: [String: BorrowedGemmaSafetensorsFile] = Dictionary(
            uniqueKeysWithValues: resources.bindings.compactMap { binding -> (String, BorrowedGemmaSafetensorsFile)? in
            guard let descriptor = binding.descriptor else { return nil }
            return (
                binding.relativePath,
                BorrowedGemmaSafetensorsFile(
                    relativePath: binding.relativePath,
                    size: binding.expectedStatus.st_size,
                    descriptor: descriptor,
                    expectedStatus: binding.expectedStatus,
                    expectedSHA256: binding.expectedSHA256
                )
            )
            }
        )
        let borrowed = BorrowedGemmaModelActivationAssets(
            requirements: resources.requirements,
            rootIdentity: resources.rootIdentity,
            smallFiles: resources.smallFiles,
            shards: readers,
            consumptionOpenCheck: { [self] in
                try requireConsumptionOpen(resourceIdentity: resourceIdentity)
            }
        )
        defer { borrowed.expire() }
        let result = try body(borrowed)
        borrowed.expire()
        try requireConsumptionOpen(
            resourceIdentity: resourceIdentity,
            cancellationCheck: cancellationCheck
        )
        try GemmaModelVerifier.revalidateActivationBindings(
            rootDescriptor: resources.rootDescriptor,
            rootStatus: resources.rootStatus,
            rootIdentity: resources.rootIdentity,
            requirements: resources.requirements,
            bindings: resources.bindings,
            cancellationCheck: {
                try self.requireConsumptionOpen(
                    resourceIdentity: resourceIdentity,
                    cancellationCheck: cancellationCheck
                )
            }
        )
        let detached: GemmaActivationResources = try lock.withLock {
            guard case .consuming(let ownedResources, closeRequested: false) = state,
                  ObjectIdentifier(ownedResources) == resourceIdentity
            else {
                throw GemmaModelVerificationError.activationAssetsUnavailable
            }
            state = .finished
            return ownedResources
        }
        didCommit = true
        detached.close()
        return result
    }

    func ownedDescriptorsForTesting() -> [Int32] {
        lock.withLock {
            let resources: GemmaActivationResources
            switch state {
            case .ready(let ownedResources), .consuming(let ownedResources, _):
                resources = ownedResources
            case .finished:
                return []
            }
            return [resources.rootDescriptor] + resources.shardDescriptors.values.sorted()
        }
    }

    private func requireConsumptionOpen(
        resourceIdentity: ObjectIdentifier,
        cancellationCheck: @Sendable () throws -> Void
    ) throws {
        try cancellationCheck()
        try requireConsumptionOpen(resourceIdentity: resourceIdentity)
    }

    private func requireConsumptionOpen(
        resourceIdentity: ObjectIdentifier
    ) throws {
        let isOpen = lock.withLock {
            guard case .consuming(let resources, closeRequested: false) = state else {
                return false
            }
            return ObjectIdentifier(resources) == resourceIdentity
        }
        guard isOpen else {
            throw GemmaModelVerificationError.activationAssetsUnavailable
        }
    }
}

private final class GemmaActivationResources {
    let rootDescriptor: Int32
    let rootStatus: stat
    let rootIdentity: GemmaModelRootIdentity
    let requirements: GemmaModelRequirements
    let smallFiles: [String: Data]
    let bindings: [GemmaActivationFileBinding]
    let shardDescriptors: [String: Int32]
    private let ownedDescriptorCloser: @Sendable (Int32) -> Void

    init(
        rootDescriptor: Int32,
        rootStatus: stat,
        rootIdentity: GemmaModelRootIdentity,
        requirements: GemmaModelRequirements,
        smallFiles: [String: Data],
        bindings: [GemmaActivationFileBinding],
        shardDescriptors: [String: Int32],
        ownedDescriptorCloser: @escaping @Sendable (Int32) -> Void
    ) {
        self.rootDescriptor = rootDescriptor
        self.rootStatus = rootStatus
        self.rootIdentity = rootIdentity
        self.requirements = requirements
        self.smallFiles = smallFiles
        self.bindings = bindings
        self.shardDescriptors = shardDescriptors
        self.ownedDescriptorCloser = ownedDescriptorCloser
    }

    func close() {
        for descriptor in shardDescriptors.values { ownedDescriptorCloser(descriptor) }
        ownedDescriptorCloser(rootDescriptor)
    }
}

/// A verified model capability with path-free public provenance.
///
/// The root remains private. `revalidate()` returns it only after checking the same directory
/// identity and every manifest entry again. Production model activation must additionally open and
/// retain the exact child files through loading, materialize MLX, and verify them again before
/// publishing the in-memory model.
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
