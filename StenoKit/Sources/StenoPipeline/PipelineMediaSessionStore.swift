import Darwin
import Foundation
import StenoLibrary
import Synchronization

enum PipelineMediaCleanupCheckpoint: Equatable, Sendable {
    case beforeRemoveSession(UUID)
    case afterRemoveSession(UUID)
}

typealias PipelineMediaCleanupAction = @Sendable (
    PipelineMediaCleanupCheckpoint
) throws -> Void

private struct PipelineMediaSessionMarker: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionID: UUID
    let nonce: UUID
    let directoryDeviceID: UInt64
    let directoryFileID: UInt64

    init(
        sessionID: UUID,
        nonce: UUID,
        directoryDeviceID: UInt64,
        directoryFileID: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.nonce = nonce
        self.directoryDeviceID = directoryDeviceID
        self.directoryFileID = directoryFileID
    }
}

final class PipelineMediaSnapshotSession: @unchecked Sendable {
    static let rootName = ".pipeline-inputs"
    static let markerName = ".owner-token.json"
    static let ownerTokenPrefix = ".owner-"
    static let ownerTokenSuffix = ".json"

    let id: UUID
    let directoryURL: URL
    let directoryDescriptor: Int32

    private let layout: LibraryLayout
    private let marker: PipelineMediaSessionMarker
    private let cleanupAction: PipelineMediaCleanupAction
    private let descriptorState: Mutex<Int32?>

    private init(
        id: UUID,
        directoryURL: URL,
        directoryDescriptor: Int32,
        layout: LibraryLayout,
        marker: PipelineMediaSessionMarker,
        cleanupAction: @escaping PipelineMediaCleanupAction
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.directoryDescriptor = directoryDescriptor
        self.layout = layout
        self.marker = marker
        self.cleanupAction = cleanupAction
        descriptorState = Mutex(directoryDescriptor)
    }

    static func create(
        layout: LibraryLayout,
        expectedVolume: dev_t,
        transaction: LibraryMutationTransaction,
        cleanupAction: @escaping PipelineMediaCleanupAction
    ) throws -> PipelineMediaSnapshotSession {
        try transaction.validate(layout: layout)
        let rootDescriptor = try openOrCreateRoot(
            layout: layout,
            expectedVolume: expectedVolume
        )
        defer { Darwin.close(rootDescriptor) }

        let id = UUID()
        let sessionName = id.uuidString.lowercased()
        guard mkdirat(rootDescriptor, sessionName, 0o700) == 0 else {
            throw POSIXFailure(operation: "create pipeline media session", code: errno)
        }
        let descriptor = openat(
            rootDescriptor,
            sessionName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let openError = POSIXFailure(
                operation: "open pipeline media session",
                code: errno
            )
            guard unlinkat(rootDescriptor, sessionName, AT_REMOVEDIR) == 0,
                  fsync(rootDescriptor) == 0 else {
                throw PipelineError.mediaCleanupRequired(id)
            }
            throw openError
        }

        do {
            guard fchmod(descriptor, 0o700) == 0 else {
                throw POSIXFailure(operation: "secure pipeline media session", code: errno)
            }
            var status = stat()
            var pathStatus = stat()
            guard fstat(descriptor, &status) == 0,
                  fstatat(
                      rootDescriptor,
                      sessionName,
                      &pathStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  isOwnedDirectory(status),
                  isSameObject(status, pathStatus),
                  status.st_dev == expectedVolume,
                  flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                throw POSIXFailure(operation: "verify pipeline media session", code: ESTALE)
            }
            let marker = PipelineMediaSessionMarker(
                sessionID: id,
                nonce: UUID(),
                directoryDeviceID: UInt64(status.st_dev),
                directoryFileID: UInt64(status.st_ino)
            )
            try writeMarker(
                marker,
                name: ownerTokenName(id),
                directoryDescriptor: rootDescriptor
            )
            try writeMarker(marker, directoryDescriptor: descriptor)
            guard fsync(descriptor) == 0, fsync(rootDescriptor) == 0 else {
                throw POSIXFailure(operation: "sync pipeline media session", code: errno)
            }
            return PipelineMediaSnapshotSession(
                id: id,
                directoryURL: layout.root
                    .appending(path: rootName, directoryHint: .isDirectory)
                    .appending(path: sessionName, directoryHint: .isDirectory),
                directoryDescriptor: descriptor,
                layout: layout,
                marker: marker,
                cleanupAction: cleanupAction
            )
        } catch {
            let operationError = error
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            do {
                try removeUnpublishedSession(
                    id: id,
                    named: sessionName,
                    rootDescriptor: rootDescriptor
                )
            } catch {
                throw PipelineError.mediaCleanupRequired(id)
            }
            throw operationError
        }
    }

    func close() throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try close(transaction: transaction)
        }
    }

    func close(transaction: LibraryMutationTransaction) throws {
        try transaction.validate(layout: layout)
        guard let descriptor = descriptorState.withLock({ $0 }) else { return }
        do {
            try cleanupAction(.beforeRemoveSession(id))
            try Self.removeOwnedSession(
                id: id,
                marker: marker,
                sessionDescriptor: descriptor,
                layout: layout,
                cleanupAction: cleanupAction
            )
            descriptorState.withLock { value in
                if let value {
                    _ = flock(value, LOCK_UN)
                    Darwin.close(value)
                }
                value = nil
            }
        } catch {
            throw PipelineError.mediaCleanupRequired(id)
        }
    }

    func abandonDescriptor() {
        descriptorState.withLock { value in
            if let value {
                _ = flock(value, LOCK_UN)
                Darwin.close(value)
            }
            value = nil
        }
    }

    deinit {
        abandonDescriptor()
    }

    static func sweepOrphans(
        layout: LibraryLayout,
        cleanupAction: @escaping PipelineMediaCleanupAction = { _ in }
    ) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try transaction.validate(layout: layout)
            let parentDescriptor = try openLibraryRoot(layout)
            defer { Darwin.close(parentDescriptor) }
            var rootStatus = stat()
            guard fstatat(
                parentDescriptor,
                rootName,
                &rootStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT { return }
                throw POSIXFailure(operation: "stat pipeline media root", code: errno)
            }
            guard isOwnedDirectory(rootStatus) else {
                throw PipelineError.invalidMediaSnapshotRoot
            }
            let rootDescriptor = openat(
                parentDescriptor,
                rootName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw PipelineError.invalidMediaSnapshotRoot
            }
            defer { Darwin.close(rootDescriptor) }
            var openedRootStatus = stat()
            guard fstat(rootDescriptor, &openedRootStatus) == 0,
                  isSameObject(rootStatus, openedRootStatus) else {
                throw PipelineError.invalidMediaSnapshotRoot
            }

            for name in try directoryEntries(rootDescriptor) {
                guard let id = UUID(uuidString: name) else { continue }
                let sessionDescriptor = openat(
                    rootDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard sessionDescriptor >= 0 else { continue }
                defer { Darwin.close(sessionDescriptor) }
                guard let marker = try? validatedMarker(
                    id: id,
                    sessionDescriptor: sessionDescriptor,
                    rootDescriptor: rootDescriptor,
                    sessionName: name
                ) else { continue }
                guard flock(sessionDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { continue }
                    throw POSIXFailure(operation: "lock pipeline media orphan", code: errno)
                }
                defer { _ = flock(sessionDescriptor, LOCK_UN) }
                do {
                    try cleanupAction(.beforeRemoveSession(id))
                    try removeOwnedSession(
                        id: id,
                        marker: marker,
                        sessionDescriptor: sessionDescriptor,
                        layout: layout,
                        cleanupAction: cleanupAction
                    )
                } catch let error as PipelineError {
                    throw error
                } catch {
                    throw PipelineError.mediaCleanupRequired(id)
                }
            }
            for name in try directoryEntries(rootDescriptor) {
                guard let id = ownerTokenID(name) else { continue }
                var sessionStatus = stat()
                guard fstatat(
                    rootDescriptor,
                    id.uuidString.lowercased(),
                    &sessionStatus,
                    AT_SYMLINK_NOFOLLOW
                ) != 0,
                    errno == ENOENT,
                    (try? validatedRootToken(
                        id: id,
                        rootDescriptor: rootDescriptor
                    )) != nil else { continue }
                do {
                    try cleanupAction(.afterRemoveSession(id))
                    try removeRootToken(id: id, rootDescriptor: rootDescriptor)
                } catch let error as PipelineError {
                    throw error
                } catch {
                    throw PipelineError.mediaCleanupRequired(id)
                }
            }
        }
    }

    private static func removeOwnedSession(
        id: UUID,
        marker: PipelineMediaSessionMarker,
        sessionDescriptor: Int32,
        layout: LibraryLayout,
        cleanupAction: PipelineMediaCleanupAction
    ) throws {
        let rootDescriptor = try openExistingRoot(layout: layout)
        defer { Darwin.close(rootDescriptor) }
        let sessionName = id.uuidString.lowercased()
        var namespaceStatus = stat()
        guard fstatat(
            rootDescriptor,
            sessionName,
            &namespaceStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            guard errno == ENOENT else {
                throw PipelineError.mediaCleanupRequired(id)
            }
            if try rootTokenExists(id: id, rootDescriptor: rootDescriptor) {
                let rootToken = try validatedRootToken(
                    id: id,
                    rootDescriptor: rootDescriptor
                )
                guard rootToken == marker else {
                    throw PipelineError.mediaCleanupRequired(id)
                }
                try cleanupAction(.afterRemoveSession(id))
                try removeRootToken(id: id, rootDescriptor: rootDescriptor)
            }
            return
        }
        let rootToken = try validatedRootToken(id: id, rootDescriptor: rootDescriptor)
        guard rootToken == marker else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        let currentMarker = try validatedMarker(
            id: id,
            sessionDescriptor: sessionDescriptor,
            rootDescriptor: rootDescriptor,
            sessionName: sessionName
        )
        guard currentMarker == marker else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        let entries = try directoryEntries(sessionDescriptor)
        let payloadNames = entries.filter { $0 != markerName }
        guard payloadNames.allSatisfy(isPayloadName) else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        for name in payloadNames {
            var status = stat()
            guard fstatat(
                sessionDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                status.st_mode & S_IFMT == S_IFREG,
                status.st_uid == getuid(),
                status.st_nlink == 1,
                status.st_dev == dev_t(marker.directoryDeviceID) else {
                throw PipelineError.mediaCleanupRequired(id)
            }
        }
        for name in payloadNames {
            guard unlinkat(sessionDescriptor, name, 0) == 0 else {
                throw POSIXFailure(operation: "remove pipeline media clone", code: errno)
            }
        }
        guard fsync(sessionDescriptor) == 0 else {
            throw POSIXFailure(operation: "sync removed pipeline media clones", code: errno)
        }
        if entries.contains(markerName) {
            guard unlinkat(sessionDescriptor, markerName, 0) == 0 else {
                throw POSIXFailure(operation: "remove pipeline media marker", code: errno)
            }
        }
        guard fsync(sessionDescriptor) == 0 else {
            throw POSIXFailure(operation: "sync removed pipeline media marker", code: errno)
        }
        guard unlinkat(rootDescriptor, sessionName, AT_REMOVEDIR) == 0,
              fsync(rootDescriptor) == 0 else {
            throw POSIXFailure(operation: "remove pipeline media session", code: errno)
        }
        try cleanupAction(.afterRemoveSession(id))
        try removeRootToken(id: id, rootDescriptor: rootDescriptor)
    }

    private static func validatedMarker(
        id: UUID,
        sessionDescriptor: Int32,
        rootDescriptor: Int32,
        sessionName: String
    ) throws -> PipelineMediaSessionMarker {
        var sessionStatus = stat()
        var pathStatus = stat()
        guard fstat(sessionDescriptor, &sessionStatus) == 0,
              fstatat(
                  rootDescriptor,
                  sessionName,
                  &pathStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              isOwnedDirectory(sessionStatus),
              isSameObject(sessionStatus, pathStatus) else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        let rootMarker = try validatedRootToken(
            id: id,
            rootDescriptor: rootDescriptor
        )
        guard rootMarker.directoryDeviceID == UInt64(sessionStatus.st_dev),
              rootMarker.directoryFileID == UInt64(sessionStatus.st_ino) else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        do {
            let marker = try readMarker(
                id: id,
                name: markerName,
                directoryDescriptor: sessionDescriptor
            )
            guard marker == rootMarker else {
                throw PipelineError.mediaCleanupRequired(id)
            }
        } catch let error as PipelineError {
            var markerStatus = stat()
            guard fstatat(
                sessionDescriptor,
                markerName,
                &markerStatus,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
                errno == ENOENT,
                try directoryEntries(sessionDescriptor).isEmpty else {
                throw error
            }
        }
        return rootMarker
    }

    private static func validatedRootToken(
        id: UUID,
        rootDescriptor: Int32
    ) throws -> PipelineMediaSessionMarker {
        let marker = try readMarker(
            id: id,
            name: ownerTokenName(id),
            directoryDescriptor: rootDescriptor
        )
        guard marker.schemaVersion == PipelineMediaSessionMarker.currentSchemaVersion,
              marker.sessionID == id else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        return marker
    }

    private static func readMarker(
        id: UUID,
        name: String,
        directoryDescriptor: Int32
    ) throws -> PipelineMediaSessionMarker {
        let markerDescriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard markerDescriptor >= 0 else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        defer { Darwin.close(markerDescriptor) }
        var markerStatus = stat()
        guard fstat(markerDescriptor, &markerStatus) == 0,
              markerStatus.st_mode & S_IFMT == S_IFREG,
              markerStatus.st_mode & 0o777 == S_IRUSR | S_IWUSR,
              markerStatus.st_uid == getuid(),
              markerStatus.st_nlink == 1,
              markerStatus.st_size > 0,
              markerStatus.st_size <= 4_096 else {
            throw PipelineError.mediaCleanupRequired(id)
        }
        let data = try readAll(
            markerDescriptor,
            expectedByteCount: Int(markerStatus.st_size)
        )
        do {
            return try JSONDecoder().decode(PipelineMediaSessionMarker.self, from: data)
        } catch {
            throw PipelineError.mediaCleanupRequired(id)
        }
    }

    private static func openOrCreateRoot(
        layout: LibraryLayout,
        expectedVolume: dev_t
    ) throws -> Int32 {
        let parentDescriptor = try openLibraryRoot(layout)
        defer { Darwin.close(parentDescriptor) }
        if mkdirat(parentDescriptor, rootName, 0o700) != 0 {
            guard errno == EEXIST else {
                throw POSIXFailure(operation: "create pipeline media root", code: errno)
            }
        }
        let descriptor = openat(
            parentDescriptor,
            rootName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PipelineError.invalidMediaSnapshotRoot
        }
        var status = stat()
        var pathStatus = stat()
        guard fchmod(descriptor, 0o700) == 0,
              fstat(descriptor, &status) == 0,
              fstatat(
                  parentDescriptor,
                  rootName,
                  &pathStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              isOwnedDirectory(status),
              isSameObject(status, pathStatus),
              status.st_dev == expectedVolume,
              fsync(descriptor) == 0,
              fsync(parentDescriptor) == 0 else {
            Darwin.close(descriptor)
            throw PipelineError.invalidMediaSnapshotRoot
        }
        var rootURL = layout.root.appending(
            path: rootName,
            directoryHint: .isDirectory
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try rootURL.setResourceValues(resourceValues)
            guard try rootURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true,
                fstat(descriptor, &status) == 0,
                fstatat(
                    parentDescriptor,
                    rootName,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                isSameObject(status, pathStatus) else {
                throw PipelineError.invalidMediaSnapshotRoot
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func openExistingRoot(layout: LibraryLayout) throws -> Int32 {
        let parentDescriptor = try openLibraryRoot(layout)
        defer { Darwin.close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            rootName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw PipelineError.invalidMediaSnapshotRoot }
        var status = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &status) == 0,
              fstatat(
                  parentDescriptor,
                  rootName,
                  &pathStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              isOwnedDirectory(status),
              isSameObject(status, pathStatus) else {
            Darwin.close(descriptor)
            throw PipelineError.invalidMediaSnapshotRoot
        }
        return descriptor
    }

    private static func openLibraryRoot(_ layout: LibraryLayout) throws -> Int32 {
        let descriptor = layout.root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open library root for pipeline media", code: errno)
        }
        return descriptor
    }

    private static func writeMarker(
        _ marker: PipelineMediaSessionMarker,
        name: String = markerName,
        directoryDescriptor: Int32
    ) throws {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "create pipeline media marker", code: errno)
        }
        defer { Darwin.close(descriptor) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw POSIXFailure(operation: "sync pipeline media marker", code: errno)
        }
    }

    private static func removeUnpublishedSession(
        id: UUID,
        named name: String,
        rootDescriptor: Int32
    ) throws {
        let descriptor = openat(
            rootDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            guard errno == ENOENT else {
                throw POSIXFailure(
                    operation: "open unpublished pipeline media session",
                    code: errno
                )
            }
            if try rootTokenExists(id: id, rootDescriptor: rootDescriptor) {
                try removeRootToken(id: id, rootDescriptor: rootDescriptor)
            }
            return
        }
        defer { Darwin.close(descriptor) }
        for entry in try directoryEntries(descriptor) {
            guard unlinkat(descriptor, entry, 0) == 0 else {
                throw POSIXFailure(
                    operation: "remove unpublished pipeline media entry",
                    code: errno
                )
            }
        }
        guard unlinkat(rootDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw POSIXFailure(
                operation: "remove unpublished pipeline media session",
                code: errno
            )
        }
        if try rootTokenExists(id: id, rootDescriptor: rootDescriptor) {
            try removeRootToken(id: id, rootDescriptor: rootDescriptor)
        } else if fsync(rootDescriptor) != 0 {
            throw POSIXFailure(
                operation: "sync unpublished pipeline media session removal",
                code: errno
            )
        }
    }

    private static func rootTokenExists(
        id: UUID,
        rootDescriptor: Int32
    ) throws -> Bool {
        var status = stat()
        if fstatat(
            rootDescriptor,
            ownerTokenName(id),
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return true
        }
        if errno == ENOENT { return false }
        throw POSIXFailure(operation: "stat pipeline media owner token", code: errno)
    }

    private static func removeRootToken(
        id: UUID,
        rootDescriptor: Int32
    ) throws {
        guard unlinkat(rootDescriptor, ownerTokenName(id), 0) == 0 else {
            if errno == ENOENT { return }
            throw POSIXFailure(operation: "remove pipeline media owner token", code: errno)
        }
        guard fsync(rootDescriptor) == 0 else {
            throw POSIXFailure(operation: "sync pipeline media owner token removal", code: errno)
        }
    }

    private static func ownerTokenName(_ id: UUID) -> String {
        ownerTokenPrefix + id.uuidString.lowercased() + ownerTokenSuffix
    }

    private static func ownerTokenID(_ name: String) -> UUID? {
        guard name.hasPrefix(ownerTokenPrefix), name.hasSuffix(ownerTokenSuffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: ownerTokenPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -ownerTokenSuffix.count)
        return UUID(uuidString: String(name[start..<end]))
    }

    private static func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0,
              lseek(duplicate, 0, SEEK_SET) >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw POSIXFailure(operation: "enumerate pipeline media directory", code: errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw POSIXFailure(operation: "enumerate pipeline media directory", code: errno)
        }
        return names.sorted()
    }

    private static func isPayloadName(_ name: String) -> Bool {
        guard name.hasPrefix("track-"), name.hasSuffix(".media") else { return false }
        let start = name.index(name.startIndex, offsetBy: "track-".count)
        let end = name.index(name.endIndex, offsetBy: -".media".count)
        return !name[start..<end].isEmpty && name[start..<end].allSatisfy(\.isNumber)
    }

    private static func isOwnedDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
            && status.st_mode & 0o777 == 0o700
            && status.st_uid == getuid()
    }

    private static func isSameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw POSIXFailure(
                        operation: "write pipeline media marker",
                        code: count == 0 ? EIO : errno
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func readAll(_ descriptor: Int32, expectedByteCount: Int) throws -> Data {
        var data = Data(count: expectedByteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = expectedByteCount
            var offset = 0
            while remaining > 0 {
                let count = pread(descriptor, pointer, remaining, off_t(offset))
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    throw POSIXFailure(
                        operation: "read pipeline media marker",
                        code: count == 0 ? EIO : errno
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
                offset += count
            }
        }
        return data
    }
}
