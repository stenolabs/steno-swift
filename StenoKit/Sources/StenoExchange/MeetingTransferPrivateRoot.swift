import Darwin
import Foundation
import Synchronization

enum MeetingTransferCleanupTarget: Equatable, Sendable {
    case file(String)
    case sessionDirectory(String)
}

typealias MeetingTransferCleanupAction = @Sendable (MeetingTransferCleanupTarget) throws -> Void

enum MeetingTransferNamespaceCheckpoint: Equatable, Sendable {
    case beforeFileRemoval(String)
    case beforeSessionDirectoryRemoval(String)
    case beforeWriterPublish(String)
}

typealias MeetingTransferNamespaceAction = @Sendable (
    MeetingTransferNamespaceCheckpoint
) throws -> Void

struct MeetingTransferFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

public struct MeetingTransferPrivateRoot: Sendable {
    public let url: URL
    let descriptor: MeetingTransferOwnedDescriptor
    let cleanupAction: MeetingTransferCleanupAction
    let namespaceAction: MeetingTransferNamespaceAction

    var directoryFileDescriptor: Int32 { descriptor.rawValue }

    public static func prepareAndVerify(at url: URL) throws -> Self {
        try prepareAndVerify(
            at: url,
            cleanupAction: { _ in },
            namespaceCheckpoint: { _ in }
        )
    }

    static func prepareAndVerify(
        at url: URL,
        cleanupAction: @escaping MeetingTransferCleanupAction,
        namespaceCheckpoint: @escaping MeetingTransferNamespaceAction = { _ in }
    ) throws -> Self {
        let path = url.path
        var existing = stat()
        var created = false

        if lstat(path, &existing) == 0 {
            if existing.st_mode & S_IFMT == S_IFLNK {
                throw MeetingTransferValidationError.privateRootIsSymbolicLink
            }
            guard existing.st_mode & S_IFMT == S_IFDIR else {
                throw MeetingTransferValidationError.privateRootIsNotDirectory
            }
        } else if errno == ENOENT {
            guard mkdir(path, S_IRWXU) == 0 else {
                throw MeetingTransferValidationError.privateRootCreationFailed
            }
            created = true
        } else {
            throw MeetingTransferValidationError.privateRootCreationFailed
        }

        let fileDescriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            if created { _ = rmdir(path) }
            if errno == ELOOP {
                throw MeetingTransferValidationError.privateRootIsSymbolicLink
            }
            throw MeetingTransferValidationError.privateRootCreationFailed
        }

        let owned = MeetingTransferOwnedDescriptor(fileDescriptor)
        do {
            if created, fchmod(fileDescriptor, S_IRWXU) != 0 {
                throw MeetingTransferValidationError.privateRootCreationFailed
            }
            var status = stat()
            guard fstat(fileDescriptor, &status) == 0 else {
                throw MeetingTransferValidationError.privateRootCreationFailed
            }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw MeetingTransferValidationError.privateRootIsNotDirectory
            }
            guard status.st_uid == geteuid() else {
                throw MeetingTransferValidationError.privateRootHasWrongOwner
            }
            guard status.st_mode & 0o7777 == 0o700 else {
                throw MeetingTransferValidationError.insecurePrivateRootPermissions
            }
            return Self(
                url: url.standardizedFileURL,
                descriptor: owned,
                cleanupAction: cleanupAction,
                namespaceAction: namespaceCheckpoint
            )
        } catch {
            owned.close()
            if created { _ = rmdir(path) }
            throw error
        }
    }

    func createSession() throws -> MeetingTransferPrivateSession {
        guard flock(directoryFileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw MeetingTransferValidationError.sessionInUse
        }
        for _ in 0..<8 {
            let name = ".stenomeeting-validation-\(UUID().uuidString)"
            guard mkdirat(directoryFileDescriptor, name, S_IRWXU) == 0 else {
                if errno == EEXIST { continue }
                throw MeetingTransferValidationError.privateSessionCreationFailed
            }
            let descriptor = openat(
                directoryFileDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                _ = unlinkat(directoryFileDescriptor, name, AT_REMOVEDIR)
                throw MeetingTransferValidationError.privateSessionCreationFailed
            }
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                Darwin.close(descriptor)
                _ = unlinkat(directoryFileDescriptor, name, AT_REMOVEDIR)
                throw MeetingTransferValidationError.privateSessionCreationFailed
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o777 == 0o700
            else {
                Darwin.close(descriptor)
                _ = unlinkat(directoryFileDescriptor, name, AT_REMOVEDIR)
                throw MeetingTransferValidationError.privateSessionCreationFailed
            }
            return MeetingTransferPrivateSession(
                root: self,
                name: name,
                descriptor: MeetingTransferOwnedDescriptor(descriptor),
                identity: MeetingTransferFileIdentity(status),
                cleanupAction: cleanupAction,
                namespaceAction: namespaceAction
            )
        }
        throw MeetingTransferValidationError.privateSessionCreationFailed
    }

    func recoverAbandonedSessions() throws {
        guard flock(directoryFileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw MeetingTransferValidationError.sessionInUse
        }
        defer { _ = flock(directoryFileDescriptor, LOCK_UN) }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { Self.isValidationSessionName($0.lastPathComponent) }

        for candidate in candidates {
            let name = candidate.lastPathComponent
            let sessionDescriptor = openat(
                directoryFileDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard sessionDescriptor >= 0 else {
                throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
            }
            defer { Darwin.close(sessionDescriptor) }
            var sessionStatus = stat()
            guard fstat(sessionDescriptor, &sessionStatus) == 0,
                  sessionStatus.st_mode & S_IFMT == S_IFDIR,
                  sessionStatus.st_uid == geteuid(),
                  sessionStatus.st_mode & 0o777 == 0o700 else {
                throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
            }
            let sessionIdentity = MeetingTransferFileIdentity(sessionStatus)
            let entries = try FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil,
                options: []
            )
            for entry in entries {
                let entryName = entry.lastPathComponent
                guard Self.isOwnedName(entryName) else {
                    throw MeetingTransferValidationError.cleanupIdentityMismatch(entryName)
                }
                var status = stat()
                guard fstatat(
                    sessionDescriptor,
                    entryName,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                    status.st_mode & S_IFMT == S_IFREG,
                    status.st_uid == geteuid(),
                    status.st_mode & 0o777 == 0o600 else {
                    throw MeetingTransferValidationError.cleanupIdentityMismatch(entryName)
                }
                try Self.quarantineAndRemove(
                    directoryFD: sessionDescriptor,
                    name: entryName,
                    identity: MeetingTransferFileIdentity(status),
                    kind: .regularFile,
                    matchingDescriptor: nil,
                    checkpoint: nil
                )
            }
            try Self.quarantineAndRemove(
                directoryFD: directoryFileDescriptor,
                name: name,
                identity: sessionIdentity,
                kind: .directory,
                matchingDescriptor: nil,
                checkpoint: nil
            )
        }
    }

    func createFile(named name: String, accessMode: Int32 = O_RDWR) throws
        -> MeetingTransferOwnedDescriptor
    {
        guard Self.isOwnedName(name) else {
            throw MeetingTransferValidationError.storageWriteFailed
        }
        let descriptor = openat(
            directoryFileDescriptor,
            name,
            accessMode | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MeetingTransferValidationError.storageWriteFailed
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            _ = unlinkat(directoryFileDescriptor, name, 0)
            throw MeetingTransferValidationError.storageWriteFailed
        }
        return MeetingTransferOwnedDescriptor(descriptor)
    }

    func identity(of fileDescriptor: Int32, named name: String) throws
        -> MeetingTransferFileIdentity
    {
        guard Self.isOwnedName(name) else {
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else {
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }
        return MeetingTransferFileIdentity(status)
    }

    func verifyFile(named name: String, identity: MeetingTransferFileIdentity) throws {
        guard Self.isOwnedName(name) else {
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }
        var current = stat()
        guard fstatat(directoryFileDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              MeetingTransferFileIdentity(current) == identity
        else {
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }
    }

    func removeFile(named name: String, identity: MeetingTransferFileIdentity) throws {
        try Self.quarantineAndRemove(
            directoryFD: directoryFileDescriptor,
            name: name,
            identity: identity,
            kind: .regularFile,
            matchingDescriptor: nil,
            checkpoint: { try namespaceAction(.beforeFileRemoval($0)) }
        )
    }

    func detachFile(
        named name: String,
        identity: MeetingTransferFileIdentity,
        matchingDescriptor: Int32
    ) throws {
        try Self.quarantineAndRemove(
            directoryFD: directoryFileDescriptor,
            name: name,
            identity: identity,
            kind: .regularFile,
            matchingDescriptor: matchingDescriptor,
            checkpoint: nil
        )
    }

    fileprivate enum OwnedEntryKind {
        case regularFile
        case directory

        var mode: mode_t {
            switch self {
            case .regularFile: S_IFREG
            case .directory: S_IFDIR
            }
        }

        var unlinkFlags: Int32 {
            let resolutionFlags = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
            switch self {
            case .regularFile:
                return resolutionFlags | AT_UNIQUE
            case .directory:
                return resolutionFlags | AT_REMOVEDIR
            }
        }
    }

    fileprivate static func quarantineAndRemove(
        directoryFD: Int32,
        name: String,
        identity: MeetingTransferFileIdentity,
        kind: OwnedEntryKind,
        matchingDescriptor: Int32?,
        checkpoint: ((String) throws -> Void)?
    ) throws {
        guard isOwnedName(name) else {
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }

        let firstQuarantine = try moveToFreshQuarantine(
            directoryFD: directoryFD,
            sourceName: name,
            logicalName: name
        )
        guard entryMatches(
            directoryFD: directoryFD,
            name: firstQuarantine,
            identity: identity,
            kind: kind
        ) else {
            try restorePreservedEntry(
                directoryFD: directoryFD,
                sourceName: firstQuarantine,
                preferredName: name,
                logicalName: name
            )
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }

        if let checkpoint {
            do {
                try checkpoint(firstQuarantine)
            } catch {
                try restorePreservedEntry(
                    directoryFD: directoryFD,
                    sourceName: firstQuarantine,
                    preferredName: name,
                    logicalName: name
                )
                throw MeetingTransferValidationError.cleanupFailed(name)
            }
        }

        let secondQuarantine = try moveToFreshQuarantine(
            directoryFD: directoryFD,
            sourceName: firstQuarantine,
            logicalName: name
        )
        guard entryMatches(
            directoryFD: directoryFD,
            name: secondQuarantine,
            identity: identity,
            kind: kind
        ) else {
            try restorePreservedEntry(
                directoryFD: directoryFD,
                sourceName: secondQuarantine,
                preferredName: firstQuarantine,
                logicalName: name
            )
            throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
        }

        guard unlinkat(directoryFD, secondQuarantine, kind.unlinkFlags) == 0 else {
            try restorePreservedEntry(
                directoryFD: directoryFD,
                sourceName: secondQuarantine,
                preferredName: name,
                logicalName: name
            )
            throw MeetingTransferValidationError.cleanupFailed(name)
        }

        if let matchingDescriptor {
            var status = stat()
            guard fstat(matchingDescriptor, &status) == 0,
                  status.st_mode & S_IFMT == kind.mode,
                  MeetingTransferFileIdentity(status) == identity,
                  status.st_nlink == 0
            else {
                throw MeetingTransferValidationError.cleanupIdentityMismatch(name)
            }
        }
    }

    private static func moveToFreshQuarantine(
        directoryFD: Int32,
        sourceName: String,
        logicalName: String
    ) throws -> String {
        let flags = UInt32(
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        )
        for _ in 0..<8 {
            let quarantine = ".stenomeeting-quarantine-\(UUID().uuidString)"
            if renameatx_np(
                directoryFD,
                sourceName,
                directoryFD,
                quarantine,
                flags
            ) == 0 {
                return quarantine
            }
            if errno == EEXIST { continue }
            if errno == ENOENT {
                throw MeetingTransferValidationError.cleanupIdentityMismatch(logicalName)
            }
            throw MeetingTransferValidationError.cleanupFailed(logicalName)
        }
        throw MeetingTransferValidationError.cleanupFailed(logicalName)
    }

    private static func entryMatches(
        directoryFD: Int32,
        name: String,
        identity: MeetingTransferFileIdentity,
        kind: OwnedEntryKind
    ) -> Bool {
        var status = stat()
        return fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0
            && status.st_mode & S_IFMT == kind.mode
            && MeetingTransferFileIdentity(status) == identity
    }

    private static func restorePreservedEntry(
        directoryFD: Int32,
        sourceName: String,
        preferredName: String,
        logicalName: String
    ) throws {
        let result = renameatx_np(
            directoryFD,
            sourceName,
            directoryFD,
            preferredName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        if result == 0 || errno == EEXIST {
            return
        }
        throw MeetingTransferValidationError.cleanupFailed(logicalName)
    }

    static func isOwnedName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func isValidationSessionName(_ name: String) -> Bool {
        let prefix = ".stenomeeting-validation-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

final class MeetingTransferPrivateSession: @unchecked Sendable {
    private struct FileRecord: Equatable, Sendable {
        let name: String
        let identity: MeetingTransferFileIdentity
    }

    private enum Phase: Equatable, Sendable {
        case active
        case detaching
        case cleaning
        case cleanupFailed
        case closed
    }

    private struct State: Sendable {
        var files: [FileRecord] = []
        var activeLeases = 0
        var phase = Phase.active
    }

    let root: MeetingTransferPrivateRoot
    let name: String
    let descriptor: MeetingTransferOwnedDescriptor
    let identity: MeetingTransferFileIdentity
    private let cleanupAction: MeetingTransferCleanupAction
    private let namespaceAction: MeetingTransferNamespaceAction
    private let state = Mutex(State())

    var url: URL { root.url.appendingPathComponent(name, isDirectory: true) }
    var directoryFileDescriptor: Int32 { descriptor.rawValue }

    init(
        root: MeetingTransferPrivateRoot,
        name: String,
        descriptor: MeetingTransferOwnedDescriptor,
        identity: MeetingTransferFileIdentity,
        cleanupAction: @escaping MeetingTransferCleanupAction,
        namespaceAction: @escaping MeetingTransferNamespaceAction
    ) {
        self.root = root
        self.name = name
        self.descriptor = descriptor
        self.identity = identity
        self.cleanupAction = cleanupAction
        self.namespaceAction = namespaceAction
    }

    func createFile(named name: String, accessMode: Int32 = O_RDWR) throws
        -> MeetingTransferOwnedDescriptor
    {
        guard MeetingTransferPrivateRoot.isOwnedName(name) else {
            throw MeetingTransferValidationError.storageWriteFailed
        }
        let fileDescriptor = openat(
            directoryFileDescriptor,
            name,
            accessMode | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw MeetingTransferValidationError.storageWriteFailed
        }
        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(fileDescriptor)
            _ = unlinkat(directoryFileDescriptor, name, 0)
            throw MeetingTransferValidationError.storageWriteFailed
        }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else {
            Darwin.close(fileDescriptor)
            _ = unlinkat(directoryFileDescriptor, name, 0)
            throw MeetingTransferValidationError.storageWriteFailed
        }
        let record = FileRecord(name: name, identity: MeetingTransferFileIdentity(status))
        let accepted = state.withLock { state -> Bool in
            guard state.phase == .active else { return false }
            state.files.append(record)
            return true
        }
        guard accepted else {
            Darwin.close(fileDescriptor)
            _ = unlinkat(directoryFileDescriptor, name, 0)
            throw MeetingTransferValidationError.sessionInUse
        }
        return MeetingTransferOwnedDescriptor(fileDescriptor)
    }

    func openVerifiedReadDescriptor(
        named name: String,
        matching sourceDescriptor: Int32
    ) throws -> (MeetingTransferOwnedDescriptor, MeetingTransferFileIdentity) {
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG
        else {
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(name)
        }
        let expectedIdentity = MeetingTransferFileIdentity(sourceStatus)
        let readDescriptor = openat(
            directoryFileDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard readDescriptor >= 0 else {
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(name)
        }
        var readStatus = stat()
        guard fstat(readDescriptor, &readStatus) == 0,
              readStatus.st_mode & S_IFMT == S_IFREG,
              MeetingTransferFileIdentity(readStatus) == expectedIdentity
        else {
            Darwin.close(readDescriptor)
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(name)
        }
        return (MeetingTransferOwnedDescriptor(readDescriptor), expectedIdentity)
    }

    func openVerifiedReadDescriptor(
        named name: String,
        identity expectedIdentity: MeetingTransferFileIdentity
    ) throws -> MeetingTransferOwnedDescriptor {
        guard state.withLock({ $0.phase == .active }) else {
            throw MeetingTransferValidationError.sessionInUse
        }
        let readDescriptor = openat(
            directoryFileDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard readDescriptor >= 0 else {
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(name)
        }
        var status = stat()
        guard fstat(readDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              MeetingTransferFileIdentity(status) == expectedIdentity else {
            Darwin.close(readDescriptor)
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(name)
        }
        return MeetingTransferOwnedDescriptor(readDescriptor)
    }

    func detachFile(named name: String, matchingDescriptor: Int32) throws {
        let record = try state.withLock { state -> FileRecord in
            guard state.phase == .active,
                  let record = state.files.first(where: { $0.name == name })
            else {
                throw MeetingTransferValidationError.sessionInUse
            }
            state.phase = .detaching
            return record
        }
        do {
            try MeetingTransferPrivateRoot.quarantineAndRemove(
                directoryFD: directoryFileDescriptor,
                name: record.name,
                identity: record.identity,
                kind: .regularFile,
                matchingDescriptor: matchingDescriptor,
                checkpoint: nil
            )
            state.withLock { state in
                state.files.removeAll { $0 == record }
                state.phase = .active
            }
        } catch {
            state.withLock { $0.phase = .active }
            throw error
        }
    }

    func acquireLease() throws -> MeetingTransferSessionUseLease {
        let accepted = state.withLock { state -> Bool in
            guard state.phase == .active else { return false }
            state.activeLeases += 1
            return true
        }
        guard accepted else {
            throw MeetingTransferValidationError.sessionInUse
        }
        return MeetingTransferSessionUseLease(session: self)
    }

    fileprivate func releaseLease() {
        state.withLock { state in
            precondition(state.activeLeases > 0, "unbalanced meeting transfer lease")
            state.activeLeases -= 1
        }
    }

    func cleanup(beforeRemovingFiles: () -> Void = {}) throws {
        let files: [FileRecord]? = try state.withLock { state in
            if state.phase == .closed { return nil }
            guard (state.phase == .active || state.phase == .cleanupFailed),
                  state.activeLeases == 0
            else {
                throw MeetingTransferValidationError.sessionInUse
            }
            state.phase = .cleaning
            return Array(state.files.reversed())
        }
        guard let files else { return }
        beforeRemovingFiles()

        do {
            for file in files {
                do {
                    try cleanupAction(.file(file.name))
                } catch {
                    throw MeetingTransferValidationError.cleanupFailed(file.name)
                }
                try MeetingTransferPrivateRoot.quarantineAndRemove(
                    directoryFD: directoryFileDescriptor,
                    name: file.name,
                    identity: file.identity,
                    kind: .regularFile,
                    matchingDescriptor: nil,
                    checkpoint: { try self.namespaceAction(.beforeFileRemoval($0)) }
                )
                state.withLock { state in
                    state.files.removeAll { $0 == file }
                }
            }

            do {
                try cleanupAction(.sessionDirectory(name))
            } catch {
                throw MeetingTransferValidationError.cleanupFailed(name)
            }
            try MeetingTransferPrivateRoot.quarantineAndRemove(
                directoryFD: root.directoryFileDescriptor,
                name: name,
                identity: identity,
                kind: .directory,
                matchingDescriptor: nil,
                checkpoint: {
                    try self.namespaceAction(.beforeSessionDirectoryRemoval($0))
                }
            )
            descriptor.close()
            state.withLock { $0.phase = .closed }
        } catch let error as MeetingTransferValidationError {
            state.withLock { $0.phase = .cleanupFailed }
            throw error
        } catch {
            state.withLock { $0.phase = .cleanupFailed }
            throw MeetingTransferValidationError.cleanupFailed(name)
        }
    }

    deinit {
        descriptor.close()
    }
}

final class MeetingTransferSessionUseLease: @unchecked Sendable {
    private let session: MeetingTransferPrivateSession
    private let isClosed = Mutex(false)

    init(session: MeetingTransferPrivateSession) {
        self.session = session
    }

    func close() {
        let shouldRelease = isClosed.withLock { closed -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldRelease {
            session.releaseLease()
        }
    }

    deinit {
        close()
    }
}

final class MeetingTransferOwnedDescriptor: @unchecked Sendable {
    private let descriptor: Mutex<Int32?>

    init(_ value: Int32) {
        descriptor = Mutex(value)
    }

    var rawValue: Int32 {
        descriptor.withLock { value in
            precondition(value != nil, "file descriptor is closed")
            return value!
        }
    }

    func close() {
        let value = descriptor.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let value { _ = Darwin.close(value) }
    }

    deinit {
        close()
    }
}
