import CryptoKit
import Darwin
import Foundation
import StenoDomain
import Synchronization

public struct NativeMeetingTransferSnapshotToken: Equatable, Sendable {
    public let meetingID: MeetingID
    let treeDigest: String

    init(meetingID: MeetingID, treeDigest: String) {
        self.meetingID = meetingID
        self.treeDigest = treeDigest
    }
}

public struct NativeMeetingTransferMatch: Equatable, Sendable {
    public let meetingID: MeetingID
    public let contentDigest: String
    public let snapshotToken: NativeMeetingTransferSnapshotToken

    public init(
        meetingID: MeetingID,
        contentDigest: String,
        snapshotToken: NativeMeetingTransferSnapshotToken
    ) {
        self.meetingID = meetingID
        self.contentDigest = contentDigest
        self.snapshotToken = snapshotToken
    }
}

enum NativeMeetingTransferSnapshotCheckpoint: Equatable, Sendable {
    case hashedChunk(relativePath: String, byteCount: Int64)
    case finishedFinalVerification
}

typealias NativeMeetingTransferSnapshotAction = @Sendable (
    NativeMeetingTransferSnapshotCheckpoint
) throws -> Void

private struct NativeMeetingTransferEntryMetadata: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let mode: mode_t
    let userID: uid_t
    let groupID: gid_t
    let linkCount: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        fileID = UInt64(status.st_ino)
        mode = status.st_mode
        userID = status.st_uid
        groupID = status.st_gid
        linkCount = UInt64(status.st_nlink)
        byteCount = Int64(status.st_size)
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private struct NativeMeetingTransferScannedEntry: Equatable {
    enum Kind: Equatable {
        case directory
        case file(byteDigest: String)
    }

    let metadata: NativeMeetingTransferEntryMetadata
    let kind: Kind
}

public struct PreparedMediaSourceIdentity: Equatable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}

/// A short-lived generic capability supplied by a higher layer while it owns
/// the underlying validation session. StenoLibrary deliberately knows
/// nothing about StenoExchange's package or audio-lease types.
public final class PreparedMediaDescriptorLease: @unchecked Sendable {
    public let sourceURL: URL

    private let closeAction: @Sendable () -> Void
    private let isClosed = Mutex(false)

    public init(
        sourceURL: URL,
        close: @escaping @Sendable () -> Void
    ) {
        self.sourceURL = sourceURL
        closeAction = close
    }

    public func close() {
        let shouldClose = isClosed.withLock { closed -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose {
            closeAction()
        }
    }

    deinit {
        close()
    }
}

/// Describes an already validated anonymous source without acquiring it.
/// `acquire` is invoked only after the Library actor has repeated its no-op,
/// conflict, and provenance checks.
public struct PreparedDescriptorBackedMediaSource: Sendable {
    public let expectedByteCount: Int64
    public let expectedSHA256: String
    public let expectedIdentity: PreparedMediaSourceIdentity?

    private let acquireAction: @Sendable () throws -> PreparedMediaDescriptorLease

    public init(
        expectedByteCount: Int64,
        expectedSHA256: String,
        expectedIdentity: PreparedMediaSourceIdentity? = nil,
        acquire: @escaping @Sendable () throws -> PreparedMediaDescriptorLease
    ) {
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.expectedIdentity = expectedIdentity
        acquireAction = acquire
    }

    func validateExpectations() throws {
        guard expectedByteCount > 0 else {
            throw LibraryError.invalidPreparedMediaSource("nonpositive expected byte count")
        }
        guard expectedSHA256.count == 64,
              expectedSHA256 == expectedSHA256.lowercased(),
              expectedSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw LibraryError.invalidPreparedMediaSource("invalid expected SHA-256")
        }
    }

    func acquire() throws -> PreparedMediaDescriptorLease {
        try acquireAction()
    }
}

public enum PreparedMediaSourceDisposition: Sendable {
    case copy(URL)
    case data(Data)
    case cloneValidatedDescriptor(PreparedDescriptorBackedMediaSource)
}

public enum PreparedMeetingCommitResult: Equatable, Sendable {
    case imported(
        MeetingID,
        importGenerationID: MeetingTransferGenerationID? = nil
    )
    case alreadyPresent(
        MeetingID,
        importGenerationID: MeetingTransferGenerationID? = nil
    )
    case commitOutcomeUncertain(
        MeetingID,
        importGenerationID: MeetingTransferGenerationID? = nil
    )
}

public extension Library {
    /// Captures every byte that can feed the current transfer export plus the
    /// identity store used to resolve confirmed display labels. A caller may
    /// materialize the canonical transfer digest between two equal tokens and
    /// pass the latter back with `NativeMeetingTransferMatch`. The commit path
    /// compares it once more under Library actor isolation immediately before
    /// deciding that a native same-ID meeting is an identical no-op.
    func nativeMeetingTransferSnapshotToken(
        for meetingID: MeetingID
    ) throws -> NativeMeetingTransferSnapshotToken {
        try nativeMeetingTransferSnapshotToken(for: meetingID, checkpoint: { _ in })
    }

    internal func nativeMeetingTransferSnapshotToken(
        for meetingID: MeetingID,
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws -> NativeMeetingTransferSnapshotToken {
        try LibraryMutationCoordination.withSharedAccess(layout: layout) {
            try nativeMeetingTransferSnapshotTokenWithoutLock(
                for: meetingID,
                checkpoint: checkpoint
            )
        }
    }

    internal func nativeMeetingTransferSnapshotTokenWithoutLock(
        for meetingID: MeetingID,
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws -> NativeMeetingTransferSnapshotToken {
        _ = try loadMeeting(meetingID)
        let meetingDescriptor = try Self.openNativeTransferDirectory(
            at: layout.meetingDirectory(meetingID)
        )
        defer { Darwin.close(meetingDescriptor) }
        var entries: [String: NativeMeetingTransferScannedEntry] = [:]
        try Self.scanNativeTransferDirectory(
            meetingDescriptor,
            relativePath: "",
            entries: &entries,
            checkpoint: checkpoint
        )

        let identityDescriptor = try Self.openNativeTransferDirectory(
            at: layout.identityDirectory
        )
        defer { Darwin.close(identityDescriptor) }
        try Self.scanNativeTransferIdentity(
            identityDescriptor,
            entries: &entries,
            checkpoint: checkpoint
        )

        try Self.verifyNativeTransferDirectory(
            meetingDescriptor,
            relativePath: "",
            expected: entries
        )
        try Self.verifyNativeTransferIdentity(
            identityDescriptor,
            expected: entries
        )
        try Self.verifyNativeTransferDirectoryPath(
            layout.meetingDirectory(meetingID),
            descriptor: meetingDescriptor
        )
        try Self.verifyNativeTransferDirectoryPath(
            layout.identityDirectory,
            descriptor: identityDescriptor
        )
        try checkpoint(.finishedFinalVerification)

        var hasher = SHA256()
        for (relativePath, entry) in entries.sorted(by: { $0.key < $1.key }) {
            Self.updateNativeTransferHasher(&hasher, value: Data(relativePath.utf8))
            let metadata = entry.metadata
            for value in [
                String(metadata.deviceID),
                String(metadata.fileID),
                String(metadata.mode),
                String(metadata.userID),
                String(metadata.groupID),
                String(metadata.linkCount),
                String(metadata.byteCount),
                String(metadata.modifiedSeconds),
                String(metadata.modifiedNanoseconds),
                String(metadata.changedSeconds),
                String(metadata.changedNanoseconds),
            ] {
                Self.updateNativeTransferHasher(&hasher, value: Data(value.utf8))
            }
            switch entry.kind {
            case .directory:
                Self.updateNativeTransferHasher(&hasher, value: Data("directory".utf8))
            case .file(let byteDigest):
                Self.updateNativeTransferHasher(&hasher, value: Data("file".utf8))
                Self.updateNativeTransferHasher(&hasher, value: Data(byteDigest.utf8))
            }
        }
        return NativeMeetingTransferSnapshotToken(
            meetingID: meetingID,
            treeDigest: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func scanNativeTransferDirectory(
        _ descriptor: Int32,
        relativePath: String,
        entries: inout [String: NativeMeetingTransferScannedEntry],
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws {
        let before = try nativeTransferDirectoryMetadata(descriptor)
        let key = relativePath.isEmpty ? "." : relativePath
        guard entries.updateValue(
            NativeMeetingTransferScannedEntry(metadata: before, kind: .directory),
            forKey: key
        ) == nil else {
            throw nativeTransferSnapshotChanged()
        }
        for name in try nativeTransferDirectoryNames(descriptor) {
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw nativeTransferSnapshotChanged()
            }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else { throw nativeTransferSnapshotChanged() }
                do {
                    defer { Darwin.close(child) }
                    guard try nativeTransferDirectoryMetadata(child)
                        == NativeMeetingTransferEntryMetadata(status) else {
                        throw nativeTransferSnapshotChanged()
                    }
                    try scanNativeTransferDirectory(
                        child,
                        relativePath: childPath,
                        entries: &entries,
                        checkpoint: checkpoint
                    )
                }
            case S_IFREG:
                try scanNativeTransferFile(
                    parentDescriptor: descriptor,
                    name: name,
                    relativePath: childPath,
                    expectedMetadata: NativeMeetingTransferEntryMetadata(status),
                    entries: &entries,
                    checkpoint: checkpoint
                )
            default:
                throw LibraryError.invalidPreparedMeetingImport(
                    "native transfer snapshot contains a nonregular entry"
                )
            }
        }
        guard try nativeTransferDirectoryMetadata(descriptor) == before else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func scanNativeTransferIdentity(
        _ descriptor: Int32,
        entries: inout [String: NativeMeetingTransferScannedEntry],
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws {
        let before = try nativeTransferDirectoryMetadata(descriptor)
        entries["identity"] = NativeMeetingTransferScannedEntry(
            metadata: before,
            kind: .directory
        )
        var status = stat()
        if fstatat(descriptor, "persons.json", &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw nativeTransferSnapshotChanged()
            }
            try scanNativeTransferFile(
                parentDescriptor: descriptor,
                name: "persons.json",
                relativePath: "identity/persons.json",
                expectedMetadata: NativeMeetingTransferEntryMetadata(status),
                entries: &entries,
                checkpoint: checkpoint
            )
        } else if errno != ENOENT {
            throw nativeTransferSnapshotChanged()
        }
        guard try nativeTransferDirectoryMetadata(descriptor) == before else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func scanNativeTransferFile(
        parentDescriptor: Int32,
        name: String,
        relativePath: String,
        expectedMetadata: NativeMeetingTransferEntryMetadata,
        entries: inout [String: NativeMeetingTransferScannedEntry],
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw nativeTransferSnapshotChanged() }
        defer { Darwin.close(descriptor) }
        var beforeStatus = stat()
        guard fstat(descriptor, &beforeStatus) == 0,
              beforeStatus.st_mode & S_IFMT == S_IFREG,
              beforeStatus.st_size >= 0,
              NativeMeetingTransferEntryMetadata(beforeStatus) == expectedMetadata else {
            throw nativeTransferSnapshotChanged()
        }
        let digest = try hashNativeTransferFile(
            descriptor,
            expectedByteCount: Int64(beforeStatus.st_size),
            relativePath: relativePath,
            checkpoint: checkpoint
        )
        var afterStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              NativeMeetingTransferEntryMetadata(afterStatus) == expectedMetadata,
              entries.updateValue(
                NativeMeetingTransferScannedEntry(
                    metadata: expectedMetadata,
                    kind: .file(byteDigest: digest)
                ),
                forKey: relativePath
              ) == nil else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func verifyNativeTransferDirectory(
        _ descriptor: Int32,
        relativePath: String,
        expected: [String: NativeMeetingTransferScannedEntry]
    ) throws {
        var visited: Set<String> = []
        try verifyNativeTransferDirectory(
            descriptor,
            relativePath: relativePath,
            expected: expected,
            visited: &visited
        )
        let meetingKeys = Set(expected.keys.filter {
            $0 != "identity" && !$0.hasPrefix("identity/")
        })
        guard visited == meetingKeys else { throw nativeTransferSnapshotChanged() }
    }

    private static func verifyNativeTransferDirectory(
        _ descriptor: Int32,
        relativePath: String,
        expected: [String: NativeMeetingTransferScannedEntry],
        visited: inout Set<String>
    ) throws {
        let key = relativePath.isEmpty ? "." : relativePath
        let before = try nativeTransferDirectoryMetadata(descriptor)
        guard expected[key] == NativeMeetingTransferScannedEntry(
            metadata: before,
            kind: .directory
        ), visited.insert(key).inserted else {
            throw nativeTransferSnapshotChanged()
        }
        for name in try nativeTransferDirectoryNames(descriptor) {
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw nativeTransferSnapshotChanged()
            }
            let metadata = NativeMeetingTransferEntryMetadata(status)
            if status.st_mode & S_IFMT == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else { throw nativeTransferSnapshotChanged() }
                do {
                    defer { Darwin.close(child) }
                    guard try nativeTransferDirectoryMetadata(child) == metadata else {
                        throw nativeTransferSnapshotChanged()
                    }
                    try verifyNativeTransferDirectory(
                        child,
                        relativePath: childPath,
                        expected: expected,
                        visited: &visited
                    )
                }
            } else {
                guard status.st_mode & S_IFMT == S_IFREG,
                      let existing = expected[childPath],
                      existing.metadata == metadata,
                      case .file = existing.kind,
                      visited.insert(childPath).inserted else {
                    throw nativeTransferSnapshotChanged()
                }
            }
        }
        guard try nativeTransferDirectoryMetadata(descriptor) == before else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func verifyNativeTransferIdentity(
        _ descriptor: Int32,
        expected: [String: NativeMeetingTransferScannedEntry]
    ) throws {
        let before = try nativeTransferDirectoryMetadata(descriptor)
        guard expected["identity"] == NativeMeetingTransferScannedEntry(
            metadata: before,
            kind: .directory
        ) else { throw nativeTransferSnapshotChanged() }
        var status = stat()
        let existing = expected["identity/persons.json"]
        if fstatat(descriptor, "persons.json", &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG,
                  let existing,
                  existing.metadata == NativeMeetingTransferEntryMetadata(status),
                  case .file = existing.kind else {
                throw nativeTransferSnapshotChanged()
            }
        } else if errno == ENOENT {
            guard existing == nil else { throw nativeTransferSnapshotChanged() }
        } else {
            throw nativeTransferSnapshotChanged()
        }
        guard try nativeTransferDirectoryMetadata(descriptor) == before else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func openNativeTransferDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw nativeTransferSnapshotChanged() }
        do {
            try verifyNativeTransferDirectoryPath(url, descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func verifyNativeTransferDirectoryPath(
        _ url: URL,
        descriptor: Int32
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw nativeTransferSnapshotChanged()
        }
    }

    private static func nativeTransferDirectoryMetadata(
        _ descriptor: Int32
    ) throws -> NativeMeetingTransferEntryMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw nativeTransferSnapshotChanged()
        }
        return NativeMeetingTransferEntryMetadata(status)
    }

    private static func nativeTransferDirectoryNames(_ descriptor: Int32) throws -> [String] {
        let copied = dup(descriptor)
        guard copied >= 0 else { throw nativeTransferSnapshotChanged() }
        guard lseek(copied, 0, SEEK_SET) >= 0 else {
            Darwin.close(copied)
            throw nativeTransferSnapshotChanged()
        }
        guard let directory = fdopendir(copied) else {
            Darwin.close(copied)
            throw nativeTransferSnapshotChanged()
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            var nameBytes = entry.pointee.d_name
            let name = withUnsafePointer(to: &nameBytes) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw nativeTransferSnapshotChanged() }
            if name != "." && name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw nativeTransferSnapshotChanged() }
        return names.sorted()
    }

    private static func hashNativeTransferFile(
        _ descriptor: Int32,
        expectedByteCount: Int64,
        relativePath: String,
        checkpoint: NativeMeetingTransferSnapshotAction
    ) throws -> String {
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < expectedByteCount {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.count), expectedByteCount - offset))
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, wanted, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "native transfer snapshot read failed"
                )
            }
            buffer.withUnsafeBytes {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])
                )
            }
            offset += Int64(count)
            try checkpoint(.hashedChunk(relativePath: relativePath, byteCount: offset))
        }
        var trailing: UInt8 = 0
        guard pread(descriptor, &trailing, 1, off_t(expectedByteCount)) == 0 else {
            throw LibraryError.invalidPreparedMeetingImport(
                "native transfer snapshot size changed"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func nativeTransferSnapshotChanged() -> LibraryError {
        LibraryError.invalidPreparedMeetingImport(
            "native transfer snapshot changed while materializing"
        )
    }

    private static func updateNativeTransferHasher(
        _ hasher: inout SHA256,
        value: Data
    ) {
        var count = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: value)
    }
}

enum PreparedMeetingImportCheckpoint: CaseIterable, Sendable {
    case beforeFileSynchronization
    case afterStagingSynchronization
    case beforeVisibleRename
    case afterVisibleRenameBeforeParentSynchronization
}

struct PreparedMeetingImportRecoveryReport: Equatable, Sendable {
    let requiresAttention: [URL]
}

struct PreparedMeetingImportDirectoryIdentity: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
}

private struct PreparedMeetingImportEntryIdentity: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let mode: mode_t
    let userID: uid_t

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        fileID = UInt64(status.st_ino)
        mode = status.st_mode & S_IFMT
        userID = status.st_uid
    }
}

private struct PreparedMeetingImportOwnershipPair: Codable, Equatable, Hashable {
    let stagingID: UUID
    let nonce: UUID
}

private struct PreparedMeetingImportOwnershipDocument: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let format = "steno-meeting-import-ownership-v1"

    let schemaVersion: Int
    let format: String
    let stagingID: UUID
    let nonce: UUID
    let directoryIdentity: PreparedMeetingImportDirectoryIdentity?

    init(
        pair: PreparedMeetingImportOwnershipPair,
        directoryIdentity: PreparedMeetingImportDirectoryIdentity? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        format = Self.format
        stagingID = pair.stagingID
        nonce = pair.nonce
        self.directoryIdentity = directoryIdentity
    }

    var pair: PreparedMeetingImportOwnershipPair {
        PreparedMeetingImportOwnershipPair(stagingID: stagingID, nonce: nonce)
    }

    var isCurrentFormat: Bool {
        schemaVersion == Self.currentSchemaVersion && format == Self.format
    }
}

final class PreparedMeetingImportOwnership {
    let meetingsDirectory: URL
    let stagingURL: URL
    let tokenURL: URL

    private let pair: PreparedMeetingImportOwnershipPair
    private var tokenIdentity: PreparedMeetingImportEntryIdentity

    private init(
        meetingsDirectory: URL,
        pair: PreparedMeetingImportOwnershipPair,
        tokenIdentity: PreparedMeetingImportEntryIdentity
    ) {
        self.meetingsDirectory = meetingsDirectory
        self.pair = pair
        self.tokenIdentity = tokenIdentity
        stagingURL = meetingsDirectory.appending(
            path: PreparedMeetingImportRecovery.stagingName(for: pair),
            directoryHint: .isDirectory
        )
        tokenURL = meetingsDirectory.appending(
            path: PreparedMeetingImportRecovery.tokenName(for: pair)
        )
    }

    static func reserve(in meetingsDirectory: URL) throws -> PreparedMeetingImportOwnership {
        let parentDescriptor = try PreparedMeetingImportRecovery.openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }

        for _ in 0..<8 {
            let pair = PreparedMeetingImportOwnershipPair(
                stagingID: UUID(),
                nonce: UUID()
            )
            let tokenName = PreparedMeetingImportRecovery.tokenName(for: pair)
            let document = PreparedMeetingImportOwnershipDocument(pair: pair)
            do {
                let identity = try PreparedMeetingImportRecovery.createExclusiveDocument(
                    document,
                    name: tokenName,
                    in: parentDescriptor
                )
                guard Darwin.fsync(parentDescriptor) == 0 else {
                    let syncError = errno
                    _ = unlinkat(parentDescriptor, tokenName, 0)
                    throw POSIXFailure(
                        operation: "fsync meeting import ownership reservation",
                        code: syncError
                    )
                }
                return PreparedMeetingImportOwnership(
                    meetingsDirectory: meetingsDirectory,
                    pair: pair,
                    tokenIdentity: identity
                )
            } catch let error as POSIXFailure where error.code == EEXIST {
                continue
            }
        }
        throw POSIXFailure(operation: "reserve meeting import ownership", code: EEXIST)
    }

    func createStagingDirectory() throws {
        let parentDescriptor = try PreparedMeetingImportRecovery.openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }
        try verifyToken(in: parentDescriptor, expectedDocumentIdentity: nil)
        let name = stagingURL.lastPathComponent
        guard mkdirat(parentDescriptor, name, S_IRWXU) == 0 else {
            throw POSIXFailure(operation: "create meeting import staging", code: errno)
        }
    }

    @discardableResult
    func bindToStagingDirectory() throws -> PreparedMeetingImportDirectoryIdentity {
        let parentDescriptor = try PreparedMeetingImportRecovery.openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }
        try verifyToken(in: parentDescriptor, expectedDocumentIdentity: nil)

        let directoryEntry = try PreparedMeetingImportRecovery.entryIdentity(
            name: stagingURL.lastPathComponent,
            in: parentDescriptor
        )
        guard directoryEntry.mode == S_IFDIR,
              directoryEntry.userID == geteuid(),
              try PreparedMeetingImportRecovery.permissions(
                name: stagingURL.lastPathComponent,
                in: parentDescriptor
              ) == S_IRWXU else {
            throw LibraryError.invalidPreparedMeetingImport(
                "invalid owned staging directory"
            )
        }
        let directoryIdentity = PreparedMeetingImportDirectoryIdentity(
            deviceID: directoryEntry.deviceID,
            fileID: directoryEntry.fileID
        )
        let temporaryName = "\(tokenURL.lastPathComponent).bind-\(UUID().uuidString).tmp"
        let replacementIdentity = try PreparedMeetingImportRecovery.createExclusiveDocument(
            PreparedMeetingImportOwnershipDocument(
                pair: pair,
                directoryIdentity: directoryIdentity
            ),
            name: temporaryName,
            in: parentDescriptor
        )
        let renameResult = renameatx_np(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            tokenURL.lastPathComponent,
            UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        guard renameResult == 0 else {
            _ = unlinkat(parentDescriptor, temporaryName, 0)
            throw POSIXFailure(operation: "bind meeting import ownership", code: errno)
        }
        tokenIdentity = replacementIdentity
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXFailure(operation: "fsync bound meeting import ownership", code: errno)
        }
        let finalDirectoryEntry = try PreparedMeetingImportRecovery.entryIdentity(
            name: stagingURL.lastPathComponent,
            in: parentDescriptor
        )
        guard finalDirectoryEntry == directoryEntry else {
            throw LibraryError.invalidPreparedMeetingImport(
                "owned staging directory identity changed"
            )
        }
        return directoryIdentity
    }

    func removeOwnedStagingDirectory(
        expectedIdentity: PreparedMeetingImportDirectoryIdentity?,
        afterQuarantineRename: (URL) throws -> Void = { _ in }
    ) throws {
        let parentDescriptor = try PreparedMeetingImportRecovery.openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }
        let record = try PreparedMeetingImportRecovery.readToken(
            name: tokenURL.lastPathComponent,
            in: parentDescriptor
        )
        guard record.document.pair == pair,
              record.document.isCurrentFormat,
              record.identity == tokenIdentity,
              (expectedIdentity == nil
                || record.document.directoryIdentity == expectedIdentity) else {
            throw LibraryError.invalidPreparedMeetingImport(
                "meeting import ownership token mismatch during cleanup"
            )
        }
        guard let entry = try? PreparedMeetingImportRecovery.entryIdentity(
            name: stagingURL.lastPathComponent,
            in: parentDescriptor
        ) else {
            return
        }
        if let effectiveIdentity = expectedIdentity ?? record.document.directoryIdentity {
            guard entry.mode == S_IFDIR,
                  entry.deviceID == effectiveIdentity.deviceID,
                  entry.fileID == effectiveIdentity.fileID else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "owned staging cleanup identity mismatch"
                )
            }
        } else {
            guard entry.mode == S_IFDIR,
                  try FileManager.default.contentsOfDirectory(
                    at: stagingURL,
                    includingPropertiesForKeys: nil
                  ).isEmpty else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "unbound staging directory is not empty"
                )
            }
        }
        try PreparedMeetingImportRecovery.quarantineAndRemove(
            name: stagingURL.lastPathComponent,
            quarantineName: PreparedMeetingImportRecovery.cleanupName(for: pair),
            expectedIdentity: entry,
            recursive: true,
            parentDescriptor: parentDescriptor,
            parentURL: meetingsDirectory,
            afterQuarantineRename: afterQuarantineRename
        )
    }

    func removeOwnedToken() throws {
        let parentDescriptor = try PreparedMeetingImportRecovery.openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }
        let record = try PreparedMeetingImportRecovery.readToken(
            name: tokenURL.lastPathComponent,
            in: parentDescriptor
        )
        guard record.document.pair == pair,
              record.document.isCurrentFormat,
              record.identity == tokenIdentity else {
            throw LibraryError.invalidPreparedMeetingImport(
                "meeting import ownership token changed"
            )
        }
        for relatedName in [
            PreparedMeetingImportRecovery.stagingName(for: pair),
            PreparedMeetingImportRecovery.cleanupName(for: pair),
        ] {
            guard let related = try PreparedMeetingImportRecovery.optionalEntryIdentity(
                name: relatedName,
                in: parentDescriptor
            ) else {
                continue
            }
            if let bound = record.document.directoryIdentity {
                if related.mode == S_IFDIR,
                   related.deviceID == bound.deviceID,
                   related.fileID == bound.fileID {
                    throw LibraryError.invalidPreparedMeetingImport(
                        "ownership token still protects imported staging"
                    )
                }
            } else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "ownership reservation still has a related entry"
                )
            }
        }
        try PreparedMeetingImportRecovery.quarantineAndRemove(
            name: tokenURL.lastPathComponent,
            expectedIdentity: record.identity,
            recursive: false,
            parentDescriptor: parentDescriptor,
            parentURL: meetingsDirectory
        )
    }

    private func verifyToken(
        in parentDescriptor: Int32,
        expectedDocumentIdentity: PreparedMeetingImportDirectoryIdentity?
    ) throws {
        let record = try PreparedMeetingImportRecovery.readToken(
            name: tokenURL.lastPathComponent,
            in: parentDescriptor
        )
        guard record.document == PreparedMeetingImportOwnershipDocument(
                pair: pair,
                directoryIdentity: expectedDocumentIdentity
              ),
              record.identity == tokenIdentity else {
            throw LibraryError.invalidPreparedMeetingImport(
                "meeting import ownership token mismatch"
            )
        }
    }
}

enum PreparedMeetingImportRecovery {
    static let stagingDirectoryPrefix = ".meeting-import-v1-"
    private static let stagingSuffix = ".tmp"
    private static let cleanupSuffix = ".cleanup"
    private static let tokenSuffix = ".owner"

    fileprivate struct TokenRecord {
        let document: PreparedMeetingImportOwnershipDocument
        let identity: PreparedMeetingImportEntryIdentity
    }

    static func recover(in meetingsDirectory: URL) throws -> PreparedMeetingImportRecoveryReport {
        let entries = try FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let parentDescriptor = try openDirectory(meetingsDirectory)
        defer { Darwin.close(parentDescriptor) }
        var stagingByPair: [PreparedMeetingImportOwnershipPair: URL] = [:]
        var cleanupByPair: [PreparedMeetingImportOwnershipPair: URL] = [:]
        var tokenByPair: [PreparedMeetingImportOwnershipPair: URL] = [:]
        var attention = Set<URL>()

        for entry in entries {
            let name = entry.lastPathComponent
            if let pair = pair(from: name, suffix: stagingSuffix) {
                stagingByPair[pair] = entry
                continue
            }
            if let pair = pair(from: name, suffix: cleanupSuffix) {
                cleanupByPair[pair] = entry
                continue
            }
            if let pair = pair(from: name, suffix: tokenSuffix) {
                tokenByPair[pair] = entry
                continue
            }
            if isUnmarkedLegacyStagingName(name) {
                attention.insert(entry)
            }
        }

        let pairs = Set(stagingByPair.keys)
            .union(cleanupByPair.keys)
            .union(tokenByPair.keys)
        pairLoop: for pair in pairs {
            let staging = stagingByPair[pair]
            let cleanup = cleanupByPair[pair]
            let token = tokenByPair[pair]
            let candidates = [staging, cleanup].compactMap { $0 }
            guard let token else {
                attention.formUnion(candidates)
                continue
            }
            let record: TokenRecord
            do {
                record = try readToken(name: token.lastPathComponent, in: parentDescriptor)
            } catch {
                attention.insert(token)
                attention.formUnion(candidates)
                continue
            }
            guard record.document.isCurrentFormat,
                  record.document.pair == pair else {
                attention.insert(token)
                attention.formUnion(candidates)
                continue
            }

            guard let bound = record.document.directoryIdentity else {
                guard cleanup == nil else {
                    attention.formUnion(candidates)
                    attention.insert(token)
                    continue
                }
                guard let staging else {
                    do {
                        try quarantineAndRemove(
                            name: token.lastPathComponent,
                            expectedIdentity: record.identity,
                            recursive: false,
                            parentDescriptor: parentDescriptor,
                            parentURL: meetingsDirectory
                        )
                    } catch {
                        attention.insert(token)
                    }
                    continue
                }
                let stagingIdentity: PreparedMeetingImportEntryIdentity
                do {
                    stagingIdentity = try entryIdentity(
                        name: staging.lastPathComponent,
                        in: parentDescriptor
                    )
                    guard stagingIdentity.mode == S_IFDIR,
                          stagingIdentity.userID == geteuid(),
                          try FileManager.default.contentsOfDirectory(
                            at: staging,
                            includingPropertiesForKeys: nil
                          ).isEmpty else {
                        attention.formUnion([staging, token])
                        continue
                    }
                    try quarantineAndRemove(
                        name: staging.lastPathComponent,
                        quarantineName: cleanupName(for: pair),
                        expectedIdentity: stagingIdentity,
                        recursive: true,
                        parentDescriptor: parentDescriptor,
                        parentURL: meetingsDirectory
                    )
                    try quarantineAndRemove(
                        name: token.lastPathComponent,
                        expectedIdentity: record.identity,
                        recursive: false,
                        parentDescriptor: parentDescriptor,
                        parentURL: meetingsDirectory
                    )
                } catch {
                    attention.formUnion([staging, token])
                }
                continue
            }

            var ownedCandidate: (
                url: URL,
                identity: PreparedMeetingImportEntryIdentity,
                isQuarantine: Bool
            )?
            for candidate in candidates {
                let candidateIdentity: PreparedMeetingImportEntryIdentity
                do {
                    candidateIdentity = try entryIdentity(
                        name: candidate.lastPathComponent,
                        in: parentDescriptor
                    )
                } catch {
                    attention.insert(candidate)
                    continue
                }
                guard candidateIdentity.mode == S_IFDIR,
                      candidateIdentity.userID == geteuid(),
                      candidateIdentity.deviceID == bound.deviceID,
                      candidateIdentity.fileID == bound.fileID else {
                    attention.insert(candidate)
                    continue
                }
                guard ownedCandidate == nil else {
                    attention.formUnion(candidates)
                    attention.insert(token)
                    continue pairLoop
                }
                ownedCandidate = (
                    candidate,
                    candidateIdentity,
                    candidate == cleanup
                )
            }

            guard let ownedCandidate else {
                if candidates.isEmpty {
                    do {
                        try quarantineAndRemove(
                            name: token.lastPathComponent,
                            expectedIdentity: record.identity,
                            recursive: false,
                            parentDescriptor: parentDescriptor,
                            parentURL: meetingsDirectory
                        )
                    } catch {
                        attention.insert(token)
                    }
                } else {
                    attention.insert(token)
                }
                continue
            }

            do {
                if ownedCandidate.isQuarantine {
                    try removeQuarantinedDirectory(
                        name: ownedCandidate.url.lastPathComponent,
                        expectedIdentity: ownedCandidate.identity,
                        parentDescriptor: parentDescriptor,
                        parentURL: meetingsDirectory
                    )
                } else {
                    try quarantineAndRemove(
                        name: ownedCandidate.url.lastPathComponent,
                        quarantineName: cleanupName(for: pair),
                        expectedIdentity: ownedCandidate.identity,
                        recursive: true,
                        parentDescriptor: parentDescriptor,
                        parentURL: meetingsDirectory
                    )
                }
                try quarantineAndRemove(
                    name: token.lastPathComponent,
                    expectedIdentity: record.identity,
                    recursive: false,
                    parentDescriptor: parentDescriptor,
                    parentURL: meetingsDirectory
                )
            } catch {
                for candidate in candidates where FileManager.default.fileExists(
                    atPath: candidate.path
                ) {
                    attention.insert(candidate)
                }
                if FileManager.default.fileExists(atPath: token.path) {
                    attention.insert(token)
                }
            }
        }

        return PreparedMeetingImportRecoveryReport(
            requiresAttention: attention.sorted { $0.path < $1.path }
        )
    }

    fileprivate static func stagingName(
        for pair: PreparedMeetingImportOwnershipPair
    ) -> String {
        "\(stagingDirectoryPrefix)\(pair.stagingID.uuidString)-\(pair.nonce.uuidString)\(stagingSuffix)"
    }

    fileprivate static func tokenName(
        for pair: PreparedMeetingImportOwnershipPair
    ) -> String {
        "\(stagingDirectoryPrefix)\(pair.stagingID.uuidString)-\(pair.nonce.uuidString)\(tokenSuffix)"
    }

    fileprivate static func cleanupName(
        for pair: PreparedMeetingImportOwnershipPair
    ) -> String {
        "\(stagingDirectoryPrefix)\(pair.stagingID.uuidString)-\(pair.nonce.uuidString)\(cleanupSuffix)"
    }

    fileprivate static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open meeting imports directory", code: errno)
        }
        return descriptor
    }

    fileprivate static func entryIdentity(
        name: String,
        in parentDescriptor: Int32
    ) throws -> PreparedMeetingImportEntryIdentity {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXFailure(operation: "stat meeting import entry", code: errno)
        }
        return PreparedMeetingImportEntryIdentity(status)
    }

    fileprivate static func optionalEntryIdentity(
        name: String,
        in parentDescriptor: Int32
    ) throws -> PreparedMeetingImportEntryIdentity? {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXFailure(operation: "stat optional meeting import entry", code: errno)
        }
        return PreparedMeetingImportEntryIdentity(status)
    }

    fileprivate static func createExclusiveDocument(
        _ document: PreparedMeetingImportOwnershipDocument,
        name: String,
        in parentDescriptor: Int32
    ) throws -> PreparedMeetingImportEntryIdentity {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "create meeting import ownership token", code: errno)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXFailure(operation: "fsync meeting import ownership token", code: errno)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
                  status.st_uid == geteuid(),
                  status.st_nlink == 1 else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "invalid meeting import ownership token"
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                throw POSIXFailure(operation: "close meeting import ownership token", code: errno)
            }
            return PreparedMeetingImportEntryIdentity(status)
        } catch {
            Darwin.close(descriptor)
            _ = unlinkat(parentDescriptor, name, 0)
            throw error
        }
    }

    fileprivate static func readToken(
        name: String,
        in parentDescriptor: Int32
    ) throws -> TokenRecord {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open meeting import ownership token", code: errno)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= 4_096 else {
            throw LibraryError.invalidPreparedMeetingImport(
                "invalid meeting import ownership token"
            )
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.read(descriptor, pointer, remaining)
                guard count > 0 else {
                    throw POSIXFailure(
                        operation: "read meeting import ownership token",
                        code: count == 0 ? EIO : errno
                    )
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        return TokenRecord(
            document: try JSONDecoder().decode(
                PreparedMeetingImportOwnershipDocument.self,
                from: data
            ),
            identity: PreparedMeetingImportEntryIdentity(status)
        )
    }

    fileprivate static func quarantineAndRemove(
        name: String,
        quarantineName: String = ".meeting-import-cleanup-\(UUID().uuidString)",
        expectedIdentity: PreparedMeetingImportEntryIdentity,
        recursive: Bool,
        parentDescriptor: Int32,
        parentURL: URL,
        afterQuarantineRename: (URL) throws -> Void = { _ in }
    ) throws {
        guard try entryIdentity(name: name, in: parentDescriptor) == expectedIdentity else {
            throw LibraryError.invalidPreparedMeetingImport(
                "meeting import cleanup identity mismatch"
            )
        }
        let result = renameatx_np(
            parentDescriptor,
            name,
            parentDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        guard result == 0 else {
            throw POSIXFailure(operation: "quarantine meeting import entry", code: errno)
        }
        guard (try? entryIdentity(name: quarantineName, in: parentDescriptor))
            == expectedIdentity else {
            _ = renameatx_np(
                parentDescriptor,
                quarantineName,
                parentDescriptor,
                name,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
            )
            throw LibraryError.invalidPreparedMeetingImport(
                "quarantined meeting import identity mismatch"
            )
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            let syncError = errno
            _ = restoreQuarantinedEntry(
                quarantineName: quarantineName,
                originalName: name,
                expectedIdentity: expectedIdentity,
                parentDescriptor: parentDescriptor
            )
            throw POSIXFailure(operation: "fsync meeting import quarantine", code: syncError)
        }
        let quarantineURL = parentURL.appending(
            path: quarantineName,
            directoryHint: recursive ? .isDirectory : .notDirectory
        )
        do {
            try afterQuarantineRename(quarantineURL)
            if recursive {
                try FileManager.default.removeItem(at: quarantineURL)
            } else {
                guard unlinkat(parentDescriptor, quarantineName, 0) == 0 else {
                    throw POSIXFailure(
                        operation: "remove meeting import ownership token",
                        code: errno
                    )
                }
            }
        } catch {
            _ = restoreQuarantinedEntry(
                quarantineName: quarantineName,
                originalName: name,
                expectedIdentity: expectedIdentity,
                parentDescriptor: parentDescriptor
            )
            _ = Darwin.fsync(parentDescriptor)
            throw error
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXFailure(operation: "fsync meeting import cleanup", code: errno)
        }
    }

    private static func restoreQuarantinedEntry(
        quarantineName: String,
        originalName: String,
        expectedIdentity: PreparedMeetingImportEntryIdentity,
        parentDescriptor: Int32
    ) -> Bool {
        guard (try? entryIdentity(name: quarantineName, in: parentDescriptor))
            == expectedIdentity else {
            return false
        }
        let result = renameatx_np(
            parentDescriptor,
            quarantineName,
            parentDescriptor,
            originalName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        guard result == 0 else { return false }
        return (try? entryIdentity(name: originalName, in: parentDescriptor))
            == expectedIdentity
    }

    private static func removeQuarantinedDirectory(
        name: String,
        expectedIdentity: PreparedMeetingImportEntryIdentity,
        parentDescriptor: Int32,
        parentURL: URL
    ) throws {
        guard try entryIdentity(name: name, in: parentDescriptor) == expectedIdentity else {
            throw LibraryError.invalidPreparedMeetingImport(
                "quarantined meeting import cleanup identity mismatch"
            )
        }
        try FileManager.default.removeItem(
            at: parentURL.appending(path: name, directoryHint: .isDirectory)
        )
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXFailure(operation: "fsync quarantined meeting import cleanup", code: errno)
        }
    }

    fileprivate static func permissions(
        name: String,
        in parentDescriptor: Int32
    ) throws -> mode_t {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXFailure(operation: "stat meeting import permissions", code: errno)
        }
        return status.st_mode & 0o777
    }

    private static func pair(
        from name: String,
        suffix: String
    ) -> PreparedMeetingImportOwnershipPair? {
        guard name.hasPrefix(stagingDirectoryPrefix), name.hasSuffix(suffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: stagingDirectoryPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let body = String(name[start..<end])
        guard body.count == 73 else { return nil }
        let separator = body.index(body.startIndex, offsetBy: 36)
        guard body[separator] == "-" else { return nil }
        let firstEnd = separator
        let secondStart = body.index(after: separator)
        guard let stagingID = UUID(uuidString: String(body[..<firstEnd])),
              let nonce = UUID(uuidString: String(body[secondStart...])) else {
            return nil
        }
        return PreparedMeetingImportOwnershipPair(stagingID: stagingID, nonce: nonce)
    }

    private static func isUnmarkedLegacyStagingName(_ name: String) -> Bool {
        guard name.hasSuffix(stagingSuffix) else { return false }
        for prefix in [stagingDirectoryPrefix, ".meeting-import-"] {
            guard name.hasPrefix(prefix) else { continue }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -stagingSuffix.count)
            if UUID(uuidString: String(name[start..<end])) != nil {
                return true
            }
        }
        return false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXFailure(operation: "write meeting import ownership token", code: errno)
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }
}

enum PreparedMediaDescriptorCloner {
    static func clone(
        _ source: PreparedDescriptorBackedMediaSource,
        to directory: URL,
        fileName: String
    ) throws {
        let lease = try source.acquire()
        defer { lease.close() }

        let sourceDescriptor = try duplicateDescriptor(from: lease.sourceURL)
        defer { Darwin.close(sourceDescriptor) }

        let sourceStatus = try validateSourceDescriptor(
            sourceDescriptor,
            expected: source
        )
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw POSIXFailure(operation: "open prepared media directory", code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LibraryError.invalidPreparedMediaSource("invalid staging directory")
        }
        guard sourceStatus.st_dev == directoryStatus.st_dev else {
            throw LibraryError.invalidPreparedMediaSource("descriptor source is on another volume")
        }

        let result = fileName.withCString {
            fclonefileat(
                sourceDescriptor,
                directoryDescriptor,
                $0,
                UInt32(CLONE_NOOWNERCOPY)
            )
        }
        guard result == 0 else {
            throw POSIXFailure(operation: "clone validated media", code: errno)
        }

        let destinationDescriptor = fileName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard destinationDescriptor >= 0 else {
            throw POSIXFailure(operation: "open cloned media", code: errno)
        }
        defer { Darwin.close(destinationDescriptor) }
        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0,
              destinationStatus.st_mode & S_IFMT == S_IFREG,
              destinationStatus.st_size == sourceStatus.st_size,
              destinationStatus.st_dev == sourceStatus.st_dev else {
            throw LibraryError.invalidPreparedMediaSource("invalid cloned media")
        }
        guard fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXFailure(operation: "protect cloned media", code: errno)
        }
    }

    private static func duplicateDescriptor(from sourceURL: URL) throws -> Int32 {
        let prefix = "/dev/fd/"
        let path = sourceURL.path
        guard sourceURL.isFileURL,
              path.hasPrefix(prefix),
              path.dropFirst(prefix.count).allSatisfy(\.isNumber),
              let rawValue = Int32(String(path.dropFirst(prefix.count))),
              rawValue > STDERR_FILENO else {
            throw LibraryError.invalidPreparedMediaSource("source is not a descriptor URL")
        }
        let duplicate = fcntl(rawValue, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw LibraryError.invalidPreparedMediaSource("descriptor source is unavailable")
        }
        return duplicate
    }

    private static func validateSourceDescriptor(
        _ descriptor: Int32,
        expected: PreparedDescriptorBackedMediaSource
    ) throws -> stat {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
            throw LibraryError.invalidPreparedMediaSource("descriptor source is not read-only")
        }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              initial.st_mode & S_IFMT == S_IFREG,
              initial.st_size >= 0,
              initial.st_nlink == 0 else {
            throw LibraryError.invalidPreparedMediaSource("descriptor source is not anonymous regular data")
        }
        guard Int64(initial.st_size) == expected.expectedByteCount else {
            throw LibraryError.invalidPreparedMediaSource("descriptor byte count mismatch")
        }
        let identity = PreparedMediaSourceIdentity(
            deviceID: UInt64(initial.st_dev),
            fileID: UInt64(initial.st_ino)
        )
        if let expectedIdentity = expected.expectedIdentity,
           expectedIdentity != identity {
            throw LibraryError.invalidPreparedMediaSource("descriptor identity mismatch")
        }
        guard try sha256(of: descriptor, byteCount: expected.expectedByteCount)
            == expected.expectedSHA256 else {
            throw LibraryError.invalidPreparedMediaSource("descriptor SHA-256 mismatch")
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_mode & S_IFMT == S_IFREG,
              final.st_size == initial.st_size,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_nlink == 0 else {
            throw LibraryError.invalidPreparedMediaSource("descriptor changed during validation")
        }
        return final
    }

    private static func sha256(of descriptor: Int32, byteCount: Int64) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset: Int64 = 0
        while offset < byteCount {
            let wanted = min(buffer.count, Int(byteCount - offset))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                pread(descriptor, rawBuffer.baseAddress, wanted, off_t(offset))
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw POSIXFailure(operation: "hash validated media", code: errno)
            }
            guard count > 0 else {
                throw LibraryError.invalidPreparedMediaSource("descriptor ended during validation")
            }
            buffer.withUnsafeBytes { rawBuffer in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: rawBuffer.baseAddress,
                    count: count
                ))
            }
            offset += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
