import CryptoKit
import Darwin
import Dispatch
import Foundation

/// The stable identity of the source directory approved by the application layer.
///
/// This is deliberately process-local input, not persisted model provenance.
public struct GemmaModelSourceIdentity: Sendable, Equatable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }
}

/// Fail-closed outcomes from copying an approved local model into Steno's store.
public enum NativeGemmaModelImportError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case unsafeSourceRoot
    case sourceIdentityMismatch
    case sourceRejected(String)
    case unsafeStore
    case insufficientSpace(required: UInt64, available: UInt64)
    case installedSnapshotMissing
    case installedSnapshotCorrupt
    case storeParentChanged
    case importAlreadyInProgress
    case publishConflict
    case orphanedStaging
    case filesystemFailure(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The native Gemma model store configuration is invalid."
        case .unsafeSourceRoot:
            "The selected native Gemma source directory is unsafe."
        case .sourceIdentityMismatch:
            "The selected native Gemma source directory changed after approval."
        case .sourceRejected(let path):
            "The native Gemma source snapshot is incomplete or unsafe at \(path)."
        case .unsafeStore:
            "Steno's native Gemma model store is unsafe."
        case .insufficientSpace:
            "There is not enough free space to import the native Gemma model."
        case .installedSnapshotMissing:
            "The approved native Gemma snapshot is not installed."
        case .installedSnapshotCorrupt:
            "An installed native Gemma snapshot exists but does not match its pinned manifest."
        case .storeParentChanged:
            "Steno's native Gemma model store changed during import."
        case .importAlreadyInProgress:
            "A native Gemma model import is already in progress."
        case .publishConflict:
            "The native Gemma snapshot could not be published without replacing another entry."
        case .orphanedStaging:
            "The private native Gemma staging directory changed and was retained for safe recovery."
        case .filesystemFailure(let operation, let code):
            "The native Gemma import failed during \(operation) with POSIX error \(code)."
        }
    }
}

/// Selects the production store without touching it, or an already-created private root in tests.
public struct NativeGemmaModelStoreConfiguration: Sendable {
    fileprivate enum Location: Sendable {
        case production(@Sendable () throws -> URL)
        case existingRoot(URL)
    }

    fileprivate let location: Location
    fileprivate let availableByteCountOverride: UInt64?

    private init(location: Location, availableByteCountOverride: UInt64? = nil) {
        self.location = location
        self.availableByteCountOverride = availableByteCountOverride
    }

    /// The provider is retained without being called. It resolves and prepares the production
    /// root only after an already-authorized import enters `importModel`.
    @_spi(StenoApp)
    public static func production(
        rootProvider: @escaping @Sendable () throws -> URL
    ) -> Self {
        Self(location: .production(rootProvider))
    }

    init(
        testRootDirectory: URL,
        availableByteCountOverride: UInt64? = nil
    ) throws {
        let root = testRootDirectory.standardizedFileURL
        guard root.isFileURL, root.path != "/" else {
            throw NativeGemmaModelImportError.invalidConfiguration
        }
        location = .existingRoot(root)
        self.availableByteCountOverride = availableByteCountOverride
    }

    fileprivate func prepareRoot() throws -> URL {
        switch location {
        case .production(let rootProvider):
            do {
                return try rootProvider()
            } catch {
                throw NativeGemmaModelImportError.unsafeStore
            }
        case .existingRoot(let root):
            return root
        }
    }
}

enum NativeGemmaModelImportCheckpoint: Sendable, Equatable {
    case sourceReady
    case sourceFileOpened(String)
    case copiedChunk(path: String, totalBytes: Int64)
    case stagingFinalized
    case beforePublish
    case afterPublish
}

typealias NativeGemmaModelImportAction = @Sendable (NativeGemmaModelImportCheckpoint) throws -> Void

/// Imports one exact, pre-approved snapshot without downloading, resolving, or loading a model.
///
/// Read-only modes protect against accidental changes and provide a tamper signal. They are not a
/// security boundary against another process running as the same macOS user. Integrity comes from
/// descriptor-bound reads, content hashes, no-replace publication, and revalidation before MLX use.
@_spi(StenoApp)
public actor NativeGemmaModelImporter {
    private static let workerQueue = DispatchQueue(
        label: "org.stenolabs.steno.native-gemma-model-import",
        qos: .utility
    )

    private let configuration: NativeGemmaModelStoreConfiguration
    private let checkpoint: NativeGemmaModelImportAction
    private var activeImport: ActiveNativeGemmaModelImport?

    public init(configuration: NativeGemmaModelStoreConfiguration) {
        self.configuration = configuration
        checkpoint = { _ in }
    }

    init(
        configuration: NativeGemmaModelStoreConfiguration,
        checkpoint: @escaping NativeGemmaModelImportAction
    ) {
        self.configuration = configuration
        self.checkpoint = checkpoint
    }

    /// Copies a source whose root identity was already bound to explicit user approval.
    ///
    /// The returned capability contains path-free public provenance and revalidates the private
    /// store path before a model loader can obtain it.
    public func importModel(
        from sourceDirectory: URL,
        expectedSourceIdentity: GemmaModelSourceIdentity,
        requirements: GemmaModelRequirements
    ) async throws -> VerifiedGemmaModel {
        guard activeImport == nil else {
            throw NativeGemmaModelImportError.importAlreadyInProgress
        }
        let importID = UUID()
        let cancellation = NativeGemmaModelImportCancellation()
        activeImport = ActiveNativeGemmaModelImport(id: importID)
        defer {
            if activeImport?.id == importID {
                activeImport = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = self.configuration
                let checkpoint = self.checkpoint
                Self.workerQueue.async {
                    do {
                        continuation.resume(returning: try Self.performImport(
                            from: sourceDirectory,
                            expectedSourceIdentity: expectedSourceIdentity,
                            requirements: requirements,
                            configuration: configuration,
                            checkpoint: checkpoint,
                            cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private nonisolated static func performImport(
        from sourceDirectory: URL,
        expectedSourceIdentity: GemmaModelSourceIdentity,
        requirements: GemmaModelRequirements,
        configuration: NativeGemmaModelStoreConfiguration,
        checkpoint: @escaping NativeGemmaModelImportAction,
        cancellation: NativeGemmaModelImportCancellation
    ) throws -> VerifiedGemmaModel {
        try cancellation.check()
        let source = try SourceSnapshotSession(
            rootURL: sourceDirectory,
            expectedIdentity: expectedSourceIdentity,
            checkpoint: checkpoint,
            cancellation: cancellation
        )
        defer { source.close() }

        let manifestData = try source.readBoundedFile(
            relativePath: requirements.manifestFileName,
            maximumByteCount: GemmaModelManifest.maximumManifestByteCount
        )
        let manifestDigest = Self.sha256(manifestData)
        guard manifestDigest == requirements.expectedManifestSHA256 else {
            throw GemmaModelVerificationError.manifestDigestMismatch(
                expected: requirements.expectedManifestSHA256,
                actual: manifestDigest
            )
        }

        let manifest = try GemmaModelManifest.decode(from: manifestData)
        try manifest.validate(against: requirements)
        try source.bindExactTree(
            manifest: manifest,
            manifestFileName: requirements.manifestFileName
        )
        try checkpoint(.sourceReady)
        try cancellation.check()

        let storeRoot = try configuration.prepareRoot()
        let store = try ModelStoreParent.open(rootURL: storeRoot)
        defer { store.close() }

        if let installed = try existingInstalledModel(
            store: store,
            requirements: requirements,
            cancellation: cancellation
        ) {
            try source.validateSnapshot()
            return installed
        }

        let requiredBytes = try Self.requiredByteCount(
            manifest: manifest,
            manifestByteCount: manifestData.count
        )
        let availableBytes: UInt64
        if let availableByteCountOverride = configuration.availableByteCountOverride {
            availableBytes = availableByteCountOverride
        } else {
            availableBytes = try store.availableByteCount()
        }
        guard availableBytes >= requiredBytes else {
            throw NativeGemmaModelImportError.insufficientSpace(
                required: requiredBytes,
                available: availableBytes
            )
        }

        let staging = try StagingTree.create(
            parent: store,
            targetDigest: requirements.expectedManifestSHA256
        )
        var published = false
        do {
            let allDirectories = Set(
                manifest.files.flatMap { GemmaModelManifest.parentDirectories(of: $0.relativePath) }
                    + GemmaModelManifest.parentDirectories(of: requirements.manifestFileName)
            )
            for path in allDirectories.sorted(by: Self.pathDepthOrder) {
                try staging.createDirectory(relativePath: path)
            }

            try staging.writeData(
                manifestData,
                relativePath: requirements.manifestFileName
            )
            for file in manifest.files.sorted(by: { $0.relativePath < $1.relativePath }) {
                try cancellation.check()
                try source.copyFile(
                    file,
                    into: staging,
                    checkpoint: checkpoint,
                    cancellation: cancellation
                )
            }
            try source.validateSnapshot()
            try staging.finalizeReadOnly()
            try checkpoint(.stagingFinalized)

            let stagingIdentity = staging.rootIdentity
            _ = try GemmaModelVerifier(requirements: requirements).verify(
                directory: staging.visibleURL,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: stagingIdentity.deviceID,
                    fileID: stagingIdentity.inode
                ),
                cancellationCheck: cancellation.check
            )
            try source.validateSnapshot()
            try store.validatePathIdentity()
            try staging.validateExactTree()
            try checkpoint(.beforePublish)
            try cancellation.check()

            do {
                try staging.publish(as: requirements.expectedManifestSHA256)
                published = true
            } catch let error as NativeGemmaModelImportError where error == .publishConflict {
                let winner = try existingInstalledModel(
                    store: store,
                    requirements: requirements,
                    cancellation: cancellation
                )
                guard let winner else {
                    throw NativeGemmaModelImportError.installedSnapshotCorrupt
                }
                try staging.removeOwnedTree()
                return winner
            }

            try store.synchronizeAfterPublish()
            // Publication is the commit point. Cancellation is honored through the final check
            // immediately before the no-replace rename. Once committed, finish verification and
            // report the installed snapshot instead of claiming that an installed model vanished.
            _ = try? checkpoint(.afterPublish)
            let installedURL = store.url.appendingPathComponent(
                requirements.expectedManifestSHA256,
                isDirectory: true
            )
            let verified = try GemmaModelVerifier(requirements: requirements).verify(
                directory: installedURL,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: stagingIdentity.deviceID,
                    fileID: stagingIdentity.inode
                ),
                cancellationCheck: {}
            )
            return verified
        } catch let importError {
            if !published {
                do {
                    try staging.removeOwnedTree()
                } catch let cleanupError {
                    throw cleanupError
                }
            }
            throw importError
        }
    }

    private nonisolated static func existingInstalledModel(
        store: ModelStoreParent,
        requirements: GemmaModelRequirements,
        cancellation: NativeGemmaModelImportCancellation
    ) throws -> VerifiedGemmaModel? {
        let leaf = requirements.expectedManifestSHA256
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(store.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            guard errno == ENOENT else {
                throw NativeGemmaModelImportError.unsafeStore
            }
            return nil
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw NativeGemmaModelImportError.installedSnapshotCorrupt
        }
        try store.validatePathIdentity()
        let identity = EntryIdentity(status)
        let url = store.url.appendingPathComponent(leaf, isDirectory: true)
        do {
            return try GemmaModelVerifier(requirements: requirements).verify(
                directory: url,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: identity.deviceID,
                    fileID: identity.inode
                ),
                cancellationCheck: cancellation.check
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeGemmaModelImportError.installedSnapshotCorrupt
        }
    }

    private static func requiredByteCount(
        manifest: GemmaModelManifest,
        manifestByteCount: Int
    ) throws -> UInt64 {
        var total = UInt64(manifestByteCount)
        for file in manifest.files {
            guard file.size >= 0 else {
                throw GemmaModelVerificationError.invalidFileSize(
                    path: file.relativePath,
                    size: file.size
                )
            }
            let (next, overflow) = total.addingReportingOverflow(UInt64(file.size))
            guard !overflow else {
                throw NativeGemmaModelImportError.invalidConfiguration
            }
            total = next
        }
        let (withMargin, overflow) = total.addingReportingOverflow(max(total / 100, 16 * 1024 * 1024))
        guard !overflow else {
            throw NativeGemmaModelImportError.invalidConfiguration
        }
        return withMargin
    }

    private static func pathDepthOrder(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Opens one exact installed snapshot as a descriptor-owned activation capability.
///
/// Resolution never discovers a model, repairs storage, follows a link, or creates the `Models/v1`
/// hierarchy. The caller supplies the complete approved requirements and receives no filesystem
/// path. The returned capability remains usable if a later path rename occurs, while its retained
/// descriptor continues to name the exact tree that passed verification.
@_spi(StenoApp)
public struct NativeGemmaInstalledModelResolver: Sendable {
    private let configuration: NativeGemmaModelStoreConfiguration

    public init(configuration: NativeGemmaModelStoreConfiguration) {
        self.configuration = configuration
    }

    public func resolve(
        requirements: GemmaModelRequirements,
        cancellationCheck: @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> VerifiedGemmaModelDirectory {
        try cancellationCheck()
        let root = try configuration.prepareRoot()
        let store = try ModelStoreParent.openExisting(rootURL: root)
        defer { store.close() }
        try store.validatePathIdentity()

        let leaf = requirements.expectedManifestSHA256
        let descriptor = leaf.withCString {
            Darwin.openat(
                store.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw NativeGemmaModelImportError.installedSnapshotMissing
            }
            throw NativeGemmaModelImportError.installedSnapshotCorrupt
        }

        do {
            try cancellationCheck()
            try store.validatePathIdentity()
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }

        // Ownership transfers at this call. The verifier closes the descriptor on every failure.
        do {
            return try GemmaModelVerifier(requirements: requirements).verify(
                adoptingDirectoryDescriptor: descriptor,
                cancellationCheck: cancellationCheck
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeGemmaModelImportError.installedSnapshotCorrupt
        }
    }
}

private struct ActiveNativeGemmaModelImport: Sendable {
    let id: UUID
}

private final class NativeGemmaModelImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }
}

private final class SourceSnapshotSession {
    private let rootURL: URL
    private let checkpoint: NativeGemmaModelImportAction
    private let cancellation: NativeGemmaModelImportCancellation
    private var directories: [String: OpenDirectory] = [:]
    private var expectedEntries: [String: [String: ExpectedEntryKind]] = [:]
    private var boundFiles: [String: EntryMetadata] = [:]
    private var isClosed = false

    init(
        rootURL: URL,
        expectedIdentity: GemmaModelSourceIdentity,
        checkpoint: @escaping NativeGemmaModelImportAction,
        cancellation: NativeGemmaModelImportCancellation
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.checkpoint = checkpoint
        self.cancellation = cancellation

        var pathStatus = stat()
        guard Darwin.lstat(self.rootURL.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_uid == geteuid()
        else {
            throw NativeGemmaModelImportError.unsafeSourceRoot
        }
        let descriptor = self.rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelImportError.unsafeSourceRoot
        }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & S_IFMT == S_IFDIR,
              openedStatus.st_uid == geteuid(),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino
        else {
            Darwin.close(descriptor)
            throw NativeGemmaModelImportError.unsafeSourceRoot
        }
        let metadata = EntryMetadata(openedStatus)
        guard metadata.deviceID == expectedIdentity.deviceID,
              metadata.inode == expectedIdentity.inode
        else {
            Darwin.close(descriptor)
            throw NativeGemmaModelImportError.sourceIdentityMismatch
        }
        directories[""] = OpenDirectory(
            descriptor: descriptor,
            metadata: metadata,
            parentPath: nil,
            name: nil
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for directory in directories.values {
            Darwin.close(directory.descriptor)
        }
        directories.removeAll()
    }

    func readBoundedFile(relativePath: String, maximumByteCount: Int) throws -> Data {
        try openParentDirectories(for: relativePath)
        let (descriptor, metadata, parent, name) = try openRegularFile(relativePath: relativePath)
        defer { Darwin.close(descriptor) }
        guard metadata.byteCount <= Int64(maximumByteCount) else {
            throw GemmaModelVerificationError.manifestTooLarge(
                limit: maximumByteCount,
                actualAtLeast: maximumByteCount + 1
            )
        }
        let data = try readData(
            descriptor: descriptor,
            maximumByteCount: maximumByteCount,
            path: relativePath
        )
        try validateOpenedFile(
            descriptor: descriptor,
            metadata: metadata,
            parent: parent,
            name: name,
            path: relativePath
        )
        boundFiles[relativePath] = metadata
        return data
    }

    func bindExactTree(manifest: GemmaModelManifest, manifestFileName: String) throws {
        var entries: [String: [String: ExpectedEntryKind]] = [:]
        func addFile(_ path: String) {
            let components = path.split(separator: "/").map(String.init)
            var parent = ""
            for component in components.dropLast() {
                entries[parent, default: [:]][component] = .directory
                parent = parent.isEmpty ? component : "\(parent)/\(component)"
            }
            if let leaf = components.last {
                entries[parent, default: [:]][leaf] = .file
            }
        }
        addFile(manifestFileName)
        for file in manifest.files {
            addFile(file.relativePath)
        }
        expectedEntries = entries

        let directoryPaths = entries.keys.filter { !$0.isEmpty }.sorted {
            let left = $0.split(separator: "/").count
            let right = $1.split(separator: "/").count
            return left == right ? $0 < $1 : left < right
        }
        for path in directoryPaths {
            try cancellation.check()
            try openDirectory(relativePath: path)
        }
        try validateExactEntries()

        let expectedFilePaths = Set(manifest.files.map(\.relativePath)).union([manifestFileName])
        for path in expectedFilePaths.sorted() where boundFiles[path] == nil {
            try cancellation.check()
            let (_, metadata, _, _) = try openRegularFile(relativePath: path, closeImmediately: true)
            boundFiles[path] = metadata
        }
        try validateSnapshot()
    }

    func copyFile(
        _ file: GemmaModelManifest.GemmaModelFile,
        into staging: StagingTree,
        checkpoint: NativeGemmaModelImportAction,
        cancellation: NativeGemmaModelImportCancellation
    ) throws {
        let (sourceDescriptor, metadata, parent, name) = try openRegularFile(
            relativePath: file.relativePath
        )
        defer { Darwin.close(sourceDescriptor) }
        guard let boundMetadata = boundFiles[file.relativePath],
              boundMetadata == metadata else {
            throw NativeGemmaModelImportError.sourceRejected(file.relativePath)
        }
        guard metadata.byteCount == file.size else {
            throw GemmaModelVerificationError.fileSizeMismatch(
                path: file.relativePath,
                expected: file.size,
                actual: metadata.byteCount
            )
        }
        try checkpoint(.sourceFileOpened(file.relativePath))
        let digest = try staging.copyFile(
            from: sourceDescriptor,
            expectedByteCount: file.size,
            relativePath: file.relativePath,
            checkpoint: checkpoint,
            cancellation: cancellation
        )
        guard digest == file.sha256 else {
            throw GemmaModelVerificationError.fileHashMismatch(
                path: file.relativePath,
                expected: file.sha256,
                actual: digest
            )
        }
        try validateOpenedFile(
            descriptor: sourceDescriptor,
            metadata: metadata,
            parent: parent,
            name: name,
            path: file.relativePath
        )
    }

    func validateSnapshot() throws {
        try cancellation.check()
        guard let root = directories[""] else {
            throw NativeGemmaModelImportError.sourceIdentityMismatch
        }
        for (path, directory) in directories {
            try cancellation.check()
            var status = stat()
            guard Darwin.fstat(directory.descriptor, &status) == 0,
                  EntryMetadata(status) == directory.metadata else {
                throw NativeGemmaModelImportError.sourceRejected(path.isEmpty ? "." : path)
            }
            if let parentPath = directory.parentPath,
               let name = directory.name,
               let parent = directories[parentPath] {
                var entryStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(parent.descriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                    EntryMetadata(entryStatus) == directory.metadata
                else {
                    throw NativeGemmaModelImportError.sourceRejected(path)
                }
            }
        }
        var pathStatus = stat()
        guard Darwin.lstat(rootURL.path, &pathStatus) == 0,
              EntryIdentity(pathStatus) == root.metadata.identity else {
            throw NativeGemmaModelImportError.sourceIdentityMismatch
        }

        for (path, metadata) in boundFiles {
            try cancellation.check()
            let (parentPath, name) = Self.parentAndLeaf(path)
            guard let parent = directories[parentPath] else {
                throw NativeGemmaModelImportError.sourceRejected(path)
            }
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(parent.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                EntryMetadata(status) == metadata
            else {
                throw NativeGemmaModelImportError.sourceRejected(path)
            }
        }
        try validateExactEntries()
    }

    private func validateExactEntries() throws {
        for (path, directory) in directories {
            try cancellation.check()
            let actualNames = try Self.directoryNames(descriptor: directory.descriptor, path: path)
            let expected = expectedEntries[path] ?? [:]
            guard actualNames == Set(expected.keys) else {
                throw NativeGemmaModelImportError.sourceRejected(path.isEmpty ? "." : path)
            }
            for name in actualNames.sorted() {
                try cancellation.check()
                guard let expectedKind = expected[name] else {
                    throw NativeGemmaModelImportError.sourceRejected(
                        path.isEmpty ? name : "\(path)/\(name)"
                    )
                }
                var status = stat()
                guard name.withCString({
                    Darwin.fstatat(directory.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                    status.st_uid == geteuid()
                else {
                    throw NativeGemmaModelImportError.sourceRejected(name)
                }
                let type = status.st_mode & S_IFMT
                guard (expectedKind == .file && type == S_IFREG)
                    || (expectedKind == .directory && type == S_IFDIR)
                else {
                    throw NativeGemmaModelImportError.sourceRejected(
                        path.isEmpty ? name : "\(path)/\(name)"
                    )
                }
            }
        }
    }

    private func openParentDirectories(for path: String) throws {
        for parent in GemmaModelManifest.parentDirectories(of: path) {
            try openDirectory(relativePath: parent)
        }
    }

    private func openDirectory(relativePath: String) throws {
        if directories[relativePath] != nil { return }
        let (parentPath, name) = Self.parentAndLeaf(relativePath)
        guard let parent = directories[parentPath] else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        var entryStatus = stat()
        guard name.withCString({
            Darwin.fstatat(parent.descriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            entryStatus.st_mode & S_IFMT == S_IFDIR,
            entryStatus.st_uid == geteuid()
        else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        let descriptor = name.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              EntryMetadata(openedStatus) == EntryMetadata(entryStatus) else {
            Darwin.close(descriptor)
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        directories[relativePath] = OpenDirectory(
            descriptor: descriptor,
            metadata: EntryMetadata(openedStatus),
            parentPath: parentPath,
            name: name
        )
    }

    private func openRegularFile(
        relativePath: String,
        closeImmediately: Bool = false
    ) throws -> (Int32, EntryMetadata, OpenDirectory, String) {
        try openParentDirectories(for: relativePath)
        let (parentPath, name) = Self.parentAndLeaf(relativePath)
        guard let parent = directories[parentPath] else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        var entryStatus = stat()
        guard name.withCString({
            Darwin.fstatat(parent.descriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            entryStatus.st_mode & S_IFMT == S_IFREG,
            entryStatus.st_uid == geteuid()
        else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        let descriptor = name.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              EntryMetadata(openedStatus) == EntryMetadata(entryStatus) else {
            Darwin.close(descriptor)
            throw NativeGemmaModelImportError.sourceRejected(relativePath)
        }
        let metadata = EntryMetadata(openedStatus)
        if closeImmediately {
            Darwin.close(descriptor)
            return (-1, metadata, parent, name)
        }
        return (descriptor, metadata, parent, name)
    }

    private func validateOpenedFile(
        descriptor: Int32,
        metadata: EntryMetadata,
        parent: OpenDirectory,
        name: String,
        path: String
    ) throws {
        var descriptorStatus = stat()
        var entryStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              EntryMetadata(descriptorStatus) == metadata,
              name.withCString({
                  Darwin.fstatat(parent.descriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              EntryMetadata(entryStatus) == metadata else {
            throw NativeGemmaModelImportError.sourceRejected(path)
        }
    }

    private func readData(
        descriptor: Int32,
        maximumByteCount: Int,
        path: String
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(1 << 20, maximumByteCount + 1))
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeGemmaModelImportError.sourceRejected(path)
            }
            guard result.count <= maximumByteCount - count else {
                throw GemmaModelVerificationError.manifestTooLarge(
                    limit: maximumByteCount,
                    actualAtLeast: maximumByteCount + 1
                )
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func parentAndLeaf(_ path: String) -> (String, String) {
        let components = path.split(separator: "/").map(String.init)
        let leaf = components.last ?? ""
        return (components.dropLast().joined(separator: "/"), leaf)
    }

    fileprivate static func directoryNames(descriptor: Int32, path: String) throws -> Set<String> {
        let enumerationDescriptor = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let directory = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw NativeGemmaModelImportError.sourceRejected(path.isEmpty ? "." : path)
        }
        defer { Darwin.closedir(directory) }

        var result = Set<String>()
        errno = 0
        while let entry = Darwin.readdir(directory) {
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw -> String? in
                let count = Int(entry.pointee.d_namlen)
                return String(bytes: raw.prefix(count), encoding: .utf8)
            }
            guard let name else {
                throw NativeGemmaModelImportError.sourceRejected(path.isEmpty ? "." : path)
            }
            if name == "." || name == ".." { continue }
            result.insert(name)
        }
        guard errno == 0 else {
            throw NativeGemmaModelImportError.sourceRejected(path.isEmpty ? "." : path)
        }
        return result
    }
}

private final class ModelStoreParent {
    let descriptor: Int32
    let url: URL
    private let identity: EntryIdentity
    private var isClosed = false

    private init(descriptor: Int32, url: URL, identity: EntryIdentity) {
        self.descriptor = descriptor
        self.url = url
        self.identity = identity
    }

    static func open(rootURL: URL) throws -> ModelStoreParent {
        try open(rootURL: rootURL, createHierarchyIfMissing: true)
    }

    static func openExisting(rootURL: URL) throws -> ModelStoreParent {
        try open(rootURL: rootURL, createHierarchyIfMissing: false)
    }

    private static func open(
        rootURL: URL,
        createHierarchyIfMissing: Bool
    ) throws -> ModelStoreParent {
        let rootDescriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        defer { Darwin.close(rootDescriptor) }
        try validateOwnedWritableDirectory(rootDescriptor, exactMode: false)

        var current = rootDescriptor
        var ownsCurrent = false
        defer {
            if ownsCurrent { Darwin.close(current) }
        }
        for component in ["Models", "v1"] {
            if createHierarchyIfMissing {
                let createResult = component.withCString {
                    Darwin.mkdirat(current, $0, mode_t(0o700))
                }
                guard createResult == 0 || errno == EEXIST else {
                    throw NativeGemmaModelImportError.unsafeStore
                }
            }
            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if !createHierarchyIfMissing, errno == ENOENT {
                    throw NativeGemmaModelImportError.installedSnapshotMissing
                }
                throw NativeGemmaModelImportError.unsafeStore
            }
            do {
                try validateOwnedWritableDirectory(next, exactMode: true)
            } catch {
                Darwin.close(next)
                throw error
            }
            if ownsCurrent { Darwin.close(current) }
            current = next
            ownsCurrent = true
        }
        var status = stat()
        guard Darwin.fstat(current, &status) == 0 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        let result = ModelStoreParent(
            descriptor: current,
            url: rootURL
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true),
            identity: EntryIdentity(status)
        )
        ownsCurrent = false
        return result
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    func validatePathIdentity() throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              EntryIdentity(descriptorStatus) == identity,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == geteuid(),
              descriptorStatus.st_mode & 0o777 == 0o700,
              Darwin.lstat(url.path, &pathStatus) == 0,
              EntryIdentity(pathStatus) == identity,
              pathStatus.st_mode & S_IFMT == S_IFDIR else {
            throw NativeGemmaModelImportError.storeParentChanged
        }
    }

    func availableByteCount() throws -> UInt64 {
        var fileSystem = statfs()
        guard Darwin.fstatfs(descriptor, &fileSystem) == 0 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        let blockSize = UInt64(max(fileSystem.f_bsize, 0))
        let blocks = UInt64(max(fileSystem.f_bavail, 0))
        let (bytes, overflow) = blockSize.multipliedReportingOverflow(by: blocks)
        return overflow ? UInt64.max : bytes
    }

    func synchronizeAfterPublish() throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "fsync model store",
                code: errno
            )
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "full fsync model store",
                code: errno
            )
        }
    }

    private static func validateOwnedWritableDirectory(
        _ descriptor: Int32,
        exactMode: Bool
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o700 == 0o700,
              status.st_mode & 0o022 == 0,
              !exactMode || status.st_mode & 0o777 == 0o700 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
    }
}

private final class StagingTree {
    private let parent: ModelStoreParent
    private(set) var rootName: String
    private(set) var rootIdentity: EntryIdentity
    private var directories: [String: MutableOpenDirectory]
    private var files: [String: EntryIdentity] = [:]
    private var isPublished = false
    private var isRemoved = false

    var visibleURL: URL {
        parent.url.appendingPathComponent(rootName, isDirectory: true)
    }

    private init(
        parent: ModelStoreParent,
        rootName: String,
        rootIdentity: EntryIdentity,
        rootDescriptor: Int32,
        rootMetadata: EntryMetadata
    ) {
        self.parent = parent
        self.rootName = rootName
        self.rootIdentity = rootIdentity
        directories = [
            "": MutableOpenDirectory(
                descriptor: rootDescriptor,
                metadata: rootMetadata,
                parentPath: nil,
                name: nil
            ),
        ]
    }

    deinit {
        for directory in directories.values {
            Darwin.close(directory.descriptor)
        }
    }

    static func create(parent: ModelStoreParent, targetDigest: String) throws -> StagingTree {
        try parent.validatePathIdentity()
        for _ in 0 ..< 32 {
            let name = ".\(targetDigest).staging-v1-\(UUID().uuidString.lowercased())"
            let createResult = name.withCString {
                Darwin.mkdirat(parent.descriptor, $0, mode_t(0o700))
            }
            if createResult != 0 {
                if errno == EEXIST { continue }
                throw NativeGemmaModelImportError.unsafeStore
            }
            let descriptor = name.withCString {
                Darwin.openat(
                    parent.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                _ = name.withCString {
                    Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR)
                }
                throw NativeGemmaModelImportError.orphanedStaging
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o777 == 0o700 else {
                Darwin.close(descriptor)
                _ = name.withCString {
                    Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR)
                }
                throw NativeGemmaModelImportError.orphanedStaging
            }
            return StagingTree(
                parent: parent,
                rootName: name,
                rootIdentity: EntryIdentity(status),
                rootDescriptor: descriptor,
                rootMetadata: EntryMetadata(status)
            )
        }
        throw NativeGemmaModelImportError.publishConflict
    }

    func createDirectory(relativePath: String) throws {
        if directories[relativePath] != nil { return }
        let (parentPath, name) = Self.parentAndLeaf(relativePath)
        guard let parentDirectory = directories[parentPath] else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        guard name.withCString({ Darwin.mkdirat(parentDirectory.descriptor, $0, mode_t(0o700)) }) == 0 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDirectory.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            _ = name.withCString {
                Darwin.unlinkat(parentDirectory.descriptor, $0, AT_REMOVEDIR)
            }
            throw NativeGemmaModelImportError.orphanedStaging
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700 else {
            Darwin.close(descriptor)
            _ = name.withCString {
                Darwin.unlinkat(parentDirectory.descriptor, $0, AT_REMOVEDIR)
            }
            throw NativeGemmaModelImportError.orphanedStaging
        }
        directories[relativePath] = MutableOpenDirectory(
            descriptor: descriptor,
            metadata: EntryMetadata(status),
            parentPath: parentPath,
            name: name
        )
        try refreshDirectory(parentPath)
    }

    func writeData(_ data: Data, relativePath: String) throws {
        let descriptor = try createFile(relativePath: relativePath)
        defer {
            refreshFile(relativePath, descriptor: descriptor)
            Darwin.close(descriptor)
        }
        try data.withUnsafeBytes { rawBuffer in
            try Self.writeAll(
                descriptor: descriptor,
                bytes: rawBuffer,
                operation: "write model manifest"
            )
        }
        try finalizeFile(descriptor: descriptor, path: relativePath)
    }

    func copyFile(
        from sourceDescriptor: Int32,
        expectedByteCount: Int64,
        relativePath: String,
        checkpoint: NativeGemmaModelImportAction,
        cancellation: NativeGemmaModelImportCancellation
    ) throws -> String {
        let destinationDescriptor = try createFile(relativePath: relativePath)
        defer {
            refreshFile(relativePath, descriptor: destinationDescriptor)
            Darwin.close(destinationDescriptor)
        }

        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sourceDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeGemmaModelImportError.sourceRejected(relativePath)
            }
            guard total <= expectedByteCount - Int64(count) else {
                throw GemmaModelVerificationError.fileSizeMismatch(
                    path: relativePath,
                    expected: expectedByteCount,
                    actual: total + Int64(count)
                )
            }
            try buffer.withUnsafeBytes { rawBuffer in
                let chunk = UnsafeRawBufferPointer(rebasing: rawBuffer.prefix(count))
                try Self.writeAll(
                    descriptor: destinationDescriptor,
                    bytes: chunk,
                    operation: "copy model file"
                )
                hasher.update(bufferPointer: chunk)
            }
            total += Int64(count)
            try checkpoint(.copiedChunk(path: relativePath, totalBytes: total))
        }
        guard total == expectedByteCount else {
            throw GemmaModelVerificationError.fileSizeMismatch(
                path: relativePath,
                expected: expectedByteCount,
                actual: total
            )
        }
        try finalizeFile(descriptor: destinationDescriptor, path: relativePath)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func finalizeReadOnly() throws {
        for path in directories.keys.sorted(by: Self.deepestPathFirst) {
            guard let directory = directories[path] else { continue }
            guard Darwin.fsync(directory.descriptor) == 0 else {
                throw NativeGemmaModelImportError.filesystemFailure(
                    operation: "fsync staging directory",
                    code: errno
                )
            }
            guard Darwin.fchmod(directory.descriptor, mode_t(0o500)) == 0 else {
                throw NativeGemmaModelImportError.filesystemFailure(
                    operation: "secure staging directory",
                    code: errno
                )
            }
            guard Darwin.fsync(directory.descriptor) == 0 else {
                throw NativeGemmaModelImportError.filesystemFailure(
                    operation: "fsync secured staging directory",
                    code: errno
                )
            }
            try refreshDirectory(path)
        }
        guard let root = directories[""] else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
        rootIdentity = root.metadata.identity
        try validateExactTree()
    }

    func validateExactTree() throws {
        let expected = expectedEntriesByDirectory()
        for (path, directory) in directories {
            var status = stat()
            guard Darwin.fstat(directory.descriptor, &status) == 0,
                  EntryIdentity(status) == directory.metadata.identity else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
            let actual = try SourceSnapshotSession.directoryNames(
                descriptor: directory.descriptor,
                path: path
            )
            guard actual == expected[path, default: []] else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
        }
        for (path, identity) in files {
            let (parentPath, name) = Self.parentAndLeaf(path)
            guard let parentDirectory = directories[parentPath] else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(parentDirectory.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                EntryIdentity(status) == identity,
                status.st_mode & S_IFMT == S_IFREG else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
        }
    }

    func publish(as targetName: String) throws {
        try parent.validatePathIdentity()
        try validateRootNameIdentity()
        let result = rootName.withCString { sourceName in
            targetName.withCString { destinationName in
                Darwin.renameatx_np(
                    parent.descriptor,
                    sourceName,
                    parent.descriptor,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw NativeGemmaModelImportError.publishConflict
            }
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "publish native Gemma model",
                code: errno
            )
        }
        isPublished = true
    }

    func removeOwnedTree() throws {
        guard !isPublished, !isRemoved else { return }
        try validateExactTree()
        try validateRootNameIdentity()

        let quarantineName = ".cleanup-v1-\(UUID().uuidString.lowercased())"
        let renameResult = rootName.withCString { sourceName in
            quarantineName.withCString { destinationName in
                Darwin.renameatx_np(
                    parent.descriptor,
                    sourceName,
                    parent.descriptor,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
        guard renameResult == 0 else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
        rootName = quarantineName
        try validateRootNameIdentity()

        for directory in directories.values {
            guard Darwin.fchmod(directory.descriptor, mode_t(0o700)) == 0 else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
        }
        for path in files.keys.sorted() {
            let (parentPath, name) = Self.parentAndLeaf(path)
            guard let parentDirectory = directories[parentPath],
                  let identity = files[path]
            else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(parentDirectory.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                EntryIdentity(status) == identity,
                name.withCString({ Darwin.unlinkat(parentDirectory.descriptor, $0, 0) }) == 0
            else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
        }
        for path in directories.keys.filter({ !$0.isEmpty }).sorted(by: Self.deepestPathFirst) {
            guard let directory = directories[path],
                  let parentPath = directory.parentPath,
                  let name = directory.name,
                  let parentDirectory = directories[parentPath]
            else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(parentDirectory.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                EntryIdentity(status) == directory.metadata.identity,
                name.withCString({
                    Darwin.unlinkat(parentDirectory.descriptor, $0, AT_REMOVEDIR)
                }) == 0
            else {
                throw NativeGemmaModelImportError.orphanedStaging
            }
        }
        try validateRootNameIdentity()
        guard rootName.withCString({
            Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR)
        }) == 0 else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
        isRemoved = true
        guard Darwin.fsync(parent.descriptor) == 0 else {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "fsync staging cleanup",
                code: errno
            )
        }
    }

    private func createFile(relativePath: String) throws -> Int32 {
        let (parentPath, name) = Self.parentAndLeaf(relativePath)
        guard let parentDirectory = directories[parentPath] else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDirectory.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o777 == 0o600 else {
            Darwin.close(descriptor)
            throw NativeGemmaModelImportError.unsafeStore
        }
        files[relativePath] = EntryIdentity(status)
        do {
            try refreshDirectory(parentPath)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func finalizeFile(descriptor: Int32, path: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "fsync staged model file",
                code: errno
            )
        }
        guard Darwin.fchmod(descriptor, mode_t(0o400)) == 0 else {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "secure staged model file",
                code: errno
            )
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeGemmaModelImportError.filesystemFailure(
                operation: "fsync secured staged model file",
                code: errno
            )
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o777 == 0o400 else {
            throw NativeGemmaModelImportError.unsafeStore
        }
        files[path] = EntryIdentity(status)
    }

    private func refreshFile(_ path: String, descriptor: Int32) {
        var status = stat()
        if Darwin.fstat(descriptor, &status) == 0 {
            files[path] = EntryIdentity(status)
        }
    }

    private func refreshDirectory(_ path: String) throws {
        guard var directory = directories[path] else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
        var status = stat()
        guard Darwin.fstat(directory.descriptor, &status) == 0 else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
        directory.metadata = EntryMetadata(status)
        directories[path] = directory
        if path.isEmpty {
            rootIdentity = directory.metadata.identity
        }
    }

    private func validateRootNameIdentity() throws {
        var status = stat()
        guard rootName.withCString({
            Darwin.fstatat(parent.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            EntryIdentity(status) == rootIdentity,
            status.st_mode & S_IFMT == S_IFDIR else {
            throw NativeGemmaModelImportError.orphanedStaging
        }
    }

    private func expectedEntriesByDirectory() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for path in files.keys {
            let (parent, name) = Self.parentAndLeaf(path)
            result[parent, default: []].insert(name)
        }
        for (path, directory) in directories where !path.isEmpty {
            if let parent = directory.parentPath, let name = directory.name {
                result[parent, default: []].insert(name)
            }
            result[path, default: []] = result[path, default: []]
        }
        result["", default: []] = result["", default: []]
        return result
    }

    private static func writeAll(
        descriptor: Int32,
        bytes: UnsafeRawBufferPointer,
        operation: String
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeGemmaModelImportError.filesystemFailure(
                    operation: operation,
                    code: errno
                )
            }
            guard count > 0 else {
                throw NativeGemmaModelImportError.filesystemFailure(
                    operation: operation,
                    code: EIO
                )
            }
            offset += count
        }
    }

    private static func parentAndLeaf(_ path: String) -> (String, String) {
        let components = path.split(separator: "/").map(String.init)
        return (components.dropLast().joined(separator: "/"), components.last ?? "")
    }

    private static func deepestPathFirst(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        return leftDepth == rightDepth ? lhs > rhs : leftDepth > rightDepth
    }
}

private enum ExpectedEntryKind {
    case file
    case directory
}

private struct OpenDirectory {
    let descriptor: Int32
    let metadata: EntryMetadata
    let parentPath: String?
    let name: String?
}

private struct MutableOpenDirectory {
    let descriptor: Int32
    var metadata: EntryMetadata
    let parentPath: String?
    let name: String?
}

private struct EntryIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let inode: UInt64

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

private struct EntryMetadata: Equatable, Sendable {
    let identity: EntryIdentity
    let mode: mode_t
    let linkCount: UInt64
    let ownerID: uid_t
    let byteCount: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var deviceID: UInt64 { identity.deviceID }
    var inode: UInt64 { identity.inode }

    init(_ status: stat) {
        identity = EntryIdentity(status)
        mode = status.st_mode
        linkCount = UInt64(status.st_nlink)
        ownerID = status.st_uid
        byteCount = Int64(status.st_size)
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}
