import Darwin
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
import Synchronization

/// A read-only descriptor for a distinct same-volume COW clone created from
/// the exact media inode selected while the library transaction was held.
final class PipelineMediaLease: @unchecked Sendable {
    let sourceURL: URL
    private let descriptor: Mutex<Int32?>
    private let snapshotSession: PipelineMediaSnapshotSession
    private let assetID: MediaAssetID
    private let expectedByteCount: Int64
    private let expectedSHA256: String

    fileprivate init(
        descriptor: Int32,
        sourceURL: URL,
        snapshotSession: PipelineMediaSnapshotSession,
        assetID: MediaAssetID,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) {
        self.descriptor = Mutex(descriptor)
        self.sourceURL = sourceURL
        self.snapshotSession = snapshotSession
        self.assetID = assetID
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
    }

    func validate() throws {
        let descriptor = try descriptor.withLock { value -> Int32 in
            guard let value else { throw PipelineError.mediaAssetChanged(assetID) }
            return value
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == S_IRUSR,
              Int64(status.st_size) == expectedByteCount,
              try MeetingTransferDigest.sha256(
                  fileDescriptor: descriptor,
                  expectedByteCount: expectedByteCount
              ) == expectedSHA256 else {
            throw PipelineError.mediaAssetChanged(assetID)
        }
    }

    func close() throws {
        let descriptor = descriptor.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let descriptor, Darwin.close(descriptor) != 0 {
            throw POSIXFailure(operation: "close pipeline media clone", code: errno)
        }
    }

    fileprivate func abandonDescriptor() {
        let descriptor = descriptor.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let descriptor { Darwin.close(descriptor) }
    }

    deinit {
        abandonDescriptor()
    }
}

struct BoundPipelineMedia: Sendable {
    let asset: MediaAsset
    let lease: PipelineMediaLease
}

typealias PipelineMediaCloneAction = @Sendable (
    Int32,
    Int32,
    String
) -> Int32

final class PipelineMediaBinding: @unchecked Sendable {
    let inputs: [BoundPipelineMedia]
    let sessionID: UUID

    private let session: PipelineMediaSnapshotSession
    private let closed = Mutex(false)

    init(inputs: [BoundPipelineMedia], session: PipelineMediaSnapshotSession) {
        self.inputs = inputs
        sessionID = session.id
        self.session = session
    }

    func close() throws {
        try close(transaction: nil)
    }

    func close(transaction: LibraryMutationTransaction) throws {
        try close(transaction: transaction as LibraryMutationTransaction?)
    }

    private func close(transaction: LibraryMutationTransaction?) throws {
        if closed.withLock({ $0 }) { return }
        var firstError: (any Error)?
        for input in inputs {
            do {
                try input.lease.close()
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            if let transaction {
                try session.close(transaction: transaction)
            } else {
                try session.close()
            }
        } catch {
            firstError = error
        }
        if let firstError { throw firstError }
        closed.withLock { $0 = true }
    }

    deinit {
        for input in inputs { input.lease.abandonDescriptor() }
        session.abandonDescriptor()
    }
}

enum PipelineMediaBinder {
    static func bind(
        assets: [MediaAsset],
        meetingID: MeetingID,
        layout: LibraryLayout,
        transaction: LibraryMutationTransaction,
        cloneAction: @escaping PipelineMediaCloneAction = { source, directory, name in
            fclonefileat(
                source,
                directory,
                name,
                UInt32(CLONE_NOOWNERCOPY)
            )
        },
        cleanupAction: @escaping PipelineMediaCleanupAction = { _ in }
    ) throws -> PipelineMediaBinding {
        try transaction.validate(layout: layout)
        let directoryURL = layout.mediaDirectory(meetingID)
        let directoryDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw POSIXFailure(operation: "open pipeline media directory", code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        var directoryPathStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              lstat(directoryURL.path, &directoryPathStatus) == 0,
              isSameDirectory(directoryStatus, directoryPathStatus) else {
            throw POSIXFailure(operation: "verify pipeline media directory", code: ESTALE)
        }

        var bound: [BoundPipelineMedia] = []
        let snapshot = try PipelineMediaSnapshotSession.create(
            layout: layout,
            expectedVolume: directoryStatus.st_dev,
            transaction: transaction,
            cleanupAction: cleanupAction
        )
        do {
            for (index, asset) in assets.enumerated() {
                guard isCanonicalFileName(asset.fileName) else {
                    throw PipelineError.invalidMediaAssetPath(asset.id)
                }
                var pathStatus = stat()
                guard fstatat(
                    directoryDescriptor,
                    asset.fileName,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                    pathStatus.st_mode & S_IFMT == S_IFREG else {
                    throw PipelineError.mediaAssetChanged(asset.id)
                }
                let descriptor = openat(
                    directoryDescriptor,
                    asset.fileName,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw PipelineError.mediaAssetChanged(asset.id)
                }
                defer { Darwin.close(descriptor) }
                var descriptorStatus = stat()
                var finalPathStatus = stat()
                guard fstat(descriptor, &descriptorStatus) == 0,
                      descriptorStatus.st_mode & S_IFMT == S_IFREG,
                      fstatat(
                          directoryDescriptor,
                          asset.fileName,
                          &finalPathStatus,
                          AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      isSameFile(pathStatus, descriptorStatus),
                      isSameFile(descriptorStatus, finalPathStatus) else {
                    throw PipelineError.mediaAssetChanged(asset.id)
                }
                let snapshotName = "track-\(index + 1).media"
                let sourceDigest = try MeetingTransferDigest.sha256(
                    fileDescriptor: descriptor,
                    expectedByteCount: Int64(descriptorStatus.st_size)
                )
                guard cloneAction(
                    descriptor,
                    snapshot.directoryDescriptor,
                    snapshotName
                ) == 0 else {
                    throw POSIXFailure(
                        operation: "clone pipeline media snapshot",
                        code: errno
                    )
                }
                let cloneDescriptor = openat(
                    snapshot.directoryDescriptor,
                    snapshotName,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard cloneDescriptor >= 0 else {
                    throw POSIXFailure(
                        operation: "open pipeline media clone",
                        code: errno
                    )
                }
                var cloneDescriptorTransferred = false
                defer {
                    if !cloneDescriptorTransferred { Darwin.close(cloneDescriptor) }
                }
                var snapshotStatus = stat()
                guard fchmod(cloneDescriptor, S_IRUSR) == 0,
                      fstat(cloneDescriptor, &snapshotStatus) == 0,
                      isValidClone(source: descriptorStatus, clone: snapshotStatus),
                      try MeetingTransferDigest.sha256(
                          fileDescriptor: cloneDescriptor,
                          expectedByteCount: Int64(snapshotStatus.st_size)
                      ) == sourceDigest else {
                    throw PipelineError.mediaAssetChanged(asset.id)
                }
                bound.append(BoundPipelineMedia(
                    asset: asset,
                    lease: PipelineMediaLease(
                        descriptor: cloneDescriptor,
                        sourceURL: snapshot.directoryURL.appending(
                            path: snapshotName
                        ),
                        snapshotSession: snapshot,
                        assetID: asset.id,
                        expectedByteCount: Int64(snapshotStatus.st_size),
                        expectedSHA256: sourceDigest
                    )
                ))
                cloneDescriptorTransferred = true
            }
            var finalDirectoryStatus = stat()
            var finalDirectoryPathStatus = stat()
            guard fstat(directoryDescriptor, &finalDirectoryStatus) == 0,
                  lstat(directoryURL.path, &finalDirectoryPathStatus) == 0,
                  isSameDirectory(directoryStatus, finalDirectoryStatus),
                  isSameDirectory(finalDirectoryStatus, finalDirectoryPathStatus) else {
                throw POSIXFailure(
                    operation: "reverify pipeline media directory",
                    code: ESTALE
                )
            }
            return PipelineMediaBinding(inputs: bound, session: snapshot)
        } catch {
            let operationError = error
            for input in bound { input.lease.abandonDescriptor() }
            do {
                try snapshot.close(transaction: transaction)
            } catch {
                throw error
            }
            throw operationError
        }
    }

    private static func isCanonicalFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || scalar.value == 0x7f
            }
    }

    private static func isSameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFDIR
            && rhs.st_mode & S_IFMT == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func isSameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG
            && rhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isValidClone(source: stat, clone: stat) -> Bool {
        source.st_mode & S_IFMT == S_IFREG
            && clone.st_mode & S_IFMT == S_IFREG
            && source.st_dev == clone.st_dev
            && source.st_ino != clone.st_ino
            && source.st_size == clone.st_size
            && clone.st_nlink == 1
            && clone.st_mode & 0o777 == S_IRUSR
    }
}
