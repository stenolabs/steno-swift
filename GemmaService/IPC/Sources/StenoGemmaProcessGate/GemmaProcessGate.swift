import Darwin
import Foundation

/// Fail-closed errors for the cross-process native Gemma exclusion gate.
public enum GemmaProcessGateError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unsafeDirectory
    case unsafeGateFile
    case infrastructureFailure
    case busy
    case timedOut
}

/// An injected stable directory and a single leaf name for the OFD-lock gate.
///
/// Production callers must use the documented stable user directory. Tests inject a private
/// directory and never open the production gate.
public struct GemmaProcessGateConfiguration: Sendable, Equatable {
    public let directoryURL: URL
    public let leafName: String

    public init(directoryURL: URL, leafName: String = "gate-v1.lock") throws {
        guard !leafName.isEmpty,
              leafName != ".",
              leafName != "..",
              !leafName.contains("/")
        else {
            throw GemmaProcessGateError.invalidConfiguration
        }
        self.directoryURL = directoryURL.standardizedFileURL
        self.leafName = leafName
    }

    public static func production() throws -> GemmaProcessGateConfiguration {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw GemmaProcessGateError.infrastructureFailure
        }
        let expectedApplicationSupport = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        guard applicationSupport.standardizedFileURL == expectedApplicationSupport else {
            throw GemmaProcessGateError.unsafeDirectory
        }
        let directoryURL = applicationSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("NativeGemma", isDirectory: true)
        try createProductionDirectoryIfNeeded()
        return try GemmaProcessGateConfiguration(directoryURL: directoryURL)
    }

    /// Creates the production directory chain one component at a time, never follows links, and
    /// validates every opened component before descending into it.
    private static func createProductionDirectoryIfNeeded() throws {
        let homePath = NSHomeDirectory()
        var current = homePath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard current >= 0 else { throw GemmaProcessGateError.unsafeDirectory }
        defer { _ = Darwin.close(current) }

        var homeStatus = stat()
        guard Darwin.fstat(current, &homeStatus) == 0,
              homeStatus.st_mode & S_IFMT == S_IFDIR,
              homeStatus.st_uid == geteuid(),
              homeStatus.st_mode & 0o022 == 0
        else {
            throw GemmaProcessGateError.unsafeDirectory
        }

        for component in ["Library", "Application Support", "Steno", "NativeGemma"] {
            let createResult = component.withCString { name in
                Darwin.mkdirat(current, name, mode_t(0o700))
            }
            guard createResult == 0 || errno == EEXIST else {
                throw GemmaProcessGateError.unsafeDirectory
            }

            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw GemmaProcessGateError.unsafeDirectory }
            var status = stat()
            guard Darwin.fstat(next, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o022 == 0
            else {
                _ = Darwin.close(next)
                throw GemmaProcessGateError.unsafeDirectory
            }
            _ = Darwin.close(current)
            current = next
        }
    }
}

/// A unique model-session description holding byte 1 exclusively.
///
/// The descriptor is released only by closing it. There is deliberately no unlock operation.
public final class GemmaModelExecutionLease: @unchecked Sendable {
    private let state = GemmaProcessGateLeaseState()

    fileprivate init(fileDescriptor: Int32) {
        state.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    /// Releases this lease by closing its owned open file description.
    public func close() {
        state.close()
    }

    /// Runs a non-escaping descriptor operation while this lease remains open.
    ///
    /// This is intended for `xpc_fd_create` at the future binding boundary. Callers must never
    /// serialize the numeric descriptor or close it themselves.
    public func withBorrowedFileDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) rethrows -> Result? {
        try state.withOpenDescriptor(body)
    }
}

/// A store-mutation description holding byte 1 exclusively.
///
/// This deliberately has no descriptor-borrowing API, so a store-mutation lease cannot be
/// transferred to or bound by the native Gemma helper. Its lock is released if its process
/// crashes because the owned open file description is closed by the kernel.
public final class GemmaStoreMutationLease: @unchecked Sendable {
    private let state = GemmaProcessGateLeaseState()

    fileprivate init(fileDescriptor: Int32) {
        state.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    /// Releases this lease by closing its owned open file description.
    public func close() {
        state.close()
    }

    /// Returns true only when the kernel reports an exclusive recording-intent lock on byte 0.
    public func recordingIntentIsPending() throws -> Bool {
        guard let result = try state.withOpenDescriptor({ descriptor in
            try GemmaProcessGate.observesRecordingIntent(on: descriptor)
        }) else {
            throw GemmaProcessGateError.unsafeGateFile
        }
        return result
    }
}

/// A recording-lifetime description holding byte 1 shared.
///
/// It is intentionally a different type from `GemmaModelExecutionLease`, so a recording
/// descriptor cannot be passed to helper binding APIs.
public final class GemmaRecordingGateLease: @unchecked Sendable {
    private let state = GemmaProcessGateLeaseState()

    fileprivate init(fileDescriptor: Int32) {
        state.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    /// Releases this lease by closing its owned open file description.
    public func close() {
        state.close()
    }
}

/// A recording transition that owns byte 0 exclusively while the caller retires local helper
/// work. It must be converted into a recording lease or closed.
public final class GemmaRecordingGateTransition: @unchecked Sendable {
    private let state = GemmaProcessGateLeaseState()

    fileprivate init(fileDescriptor: Int32) {
        state.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    /// Acquires byte 1 shared on this exact open file description, releases byte 0, and returns
    /// the recording-lifetime lease. Deadline and cancellation close the transition descriptor.
    public func acquireRecordingLease(
        until deadline: ContinuousClock.Instant
    ) async throws -> GemmaRecordingGateLease {
        // Transfer sole ownership to this operation before its first suspension point.
        // A concurrent second conversion or `close()` can then neither reuse nor close this fd.
        guard let descriptor = state.take() else {
            throw GemmaProcessGateError.unsafeGateFile
        }
        do {
            try await GemmaProcessGate.acquireRecordingExecution(
                fileDescriptor: descriptor,
                until: deadline
            )
            return GemmaRecordingGateLease(fileDescriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Aborts this transition by closing the fresh descriptor and releasing byte 0.
    public func close() {
        state.close()
    }
}

/// The MLX-free macOS OFD-lock boundary between recording and native Gemma execution.
public struct GemmaProcessGate: Sendable {
    private static let admissionByte: off_t = 0
    private static let executionByte: off_t = 1
    private static let initialBackoffNanoseconds: UInt64 = 1_000_000
    private static let maximumBackoffNanoseconds: UInt64 = 20_000_000

    public let configuration: GemmaProcessGateConfiguration

    public init(configuration: GemmaProcessGateConfiguration) {
        self.configuration = configuration
    }

    /// Acquires one complete model session: byte 0 shared while admitting, then byte 1 exclusive.
    public func acquireModelExecution() throws -> GemmaModelExecutionLease {
        GemmaModelExecutionLease(fileDescriptor: try acquireExclusiveExecutionDescription())
    }

    /// Acquires one store mutation: byte 0 shared while admitting, then byte 1 exclusively.
    ///
    /// The returned lease intentionally cannot be used at the helper binding boundary.
    public func acquireStoreMutation() throws -> GemmaStoreMutationLease {
        GemmaStoreMutationLease(fileDescriptor: try acquireExclusiveExecutionDescription())
    }

    /// Starts a recording transition by acquiring byte 0 exclusively with bounded retry.
    public func beginRecordingTransition(
        until deadline: ContinuousClock.Instant
    ) async throws -> GemmaRecordingGateTransition {
        let descriptor = try openValidatedDescription()
        do {
            try await Self.acquireLock(
                fileDescriptor: descriptor,
                type: Int16(F_WRLCK),
                byte: Self.admissionByte,
                until: deadline
            )
            return GemmaRecordingGateTransition(fileDescriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Convenience for gate-only callers that have no local helper-retirement phase.
    public func acquireRecordingLease(
        until deadline: ContinuousClock.Instant
    ) async throws -> GemmaRecordingGateLease {
        let transition = try await beginRecordingTransition(until: deadline)
        return try await transition.acquireRecordingLease(until: deadline)
    }

    /// Adopts the helper's duplicated binding descriptor and acquires or confirms byte 1 exclusive.
    ///
    /// The helper cannot prove the original path. Its caller must establish the mutually
    /// authenticated XPC identity before using this operation.
    public static func adoptHelperExecutionDescriptor(
        _ fileDescriptor: Int32
    ) throws -> GemmaModelExecutionLease {
        guard fileDescriptor >= 0 else {
            throw GemmaProcessGateError.unsafeGateFile
        }
        do {
            try validateOpenGateFile(fileDescriptor)
            try setLock(
                fileDescriptor: fileDescriptor,
                type: Int16(F_WRLCK),
                byte: executionByte
            )
            return GemmaModelExecutionLease(fileDescriptor: fileDescriptor)
        } catch {
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    /// Returns true only when the kernel reports an exclusive recording-intent lock on byte 0.
    public static func helperObservesRecordingIntent(
        for lease: GemmaModelExecutionLease
    ) throws -> Bool {
        guard let result = try lease.withBorrowedFileDescriptor({ descriptor in
            try observesRecordingIntent(on: descriptor)
        }) else {
            throw GemmaProcessGateError.unsafeGateFile
        }
        return result
    }

    private func acquireExclusiveExecutionDescription() throws -> Int32 {
        let descriptor = try openValidatedDescription()
        do {
            try Self.setLock(
                fileDescriptor: descriptor,
                type: Int16(F_RDLCK),
                byte: Self.admissionByte
            )
            try Self.setLock(
                fileDescriptor: descriptor,
                type: Int16(F_WRLCK),
                byte: Self.executionByte
            )
            try Self.setLock(
                fileDescriptor: descriptor,
                type: Int16(F_UNLCK),
                byte: Self.admissionByte
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openValidatedDescription() throws -> Int32 {
        let directoryPath = configuration.directoryURL.path
        let directoryDescriptor = directoryPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw GemmaProcessGateError.unsafeDirectory
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              Self.isDirectory(directoryStatus),
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o022 == 0
        else {
            throw GemmaProcessGateError.unsafeDirectory
        }

        let descriptor = configuration.leafName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw GemmaProcessGateError.unsafeGateFile
        }

        do {
            try Self.validateOpenGateFile(descriptor)
            var pathnameStatus = stat()
            let statResult = configuration.leafName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &pathnameStatus, AT_SYMLINK_NOFOLLOW)
            }
            var descriptorStatus = stat()
            guard statResult == 0,
                  Darwin.fstat(descriptor, &descriptorStatus) == 0,
                  descriptorStatus.st_dev == pathnameStatus.st_dev,
                  descriptorStatus.st_ino == pathnameStatus.st_ino
            else {
                throw GemmaProcessGateError.unsafeGateFile
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateOpenGateFile(_ fileDescriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              isRegularFile(status),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0
        else {
            throw GemmaProcessGateError.unsafeGateFile
        }
    }

    fileprivate static func acquireRecordingExecution(
        fileDescriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) async throws {
        try await acquireLock(
            fileDescriptor: fileDescriptor,
            type: Int16(F_RDLCK),
            byte: executionByte,
            until: deadline
        )
        try setLock(
            fileDescriptor: fileDescriptor,
            type: Int16(F_UNLCK),
            byte: admissionByte
        )
    }

    private static func acquireLock(
        fileDescriptor: Int32,
        type: Int16,
        byte: off_t,
        until deadline: ContinuousClock.Instant
    ) async throws {
        let clock = ContinuousClock()
        var backoffNanoseconds = initialBackoffNanoseconds
        while true {
            try Task.checkCancellation()
            do {
                try Self.setLock(fileDescriptor: fileDescriptor, type: type, byte: byte)
                return
            } catch GemmaProcessGateError.busy {
                let now = clock.now
                guard now < deadline else {
                    throw GemmaProcessGateError.timedOut
                }
                let candidate = now.advanced(by: .nanoseconds(Int64(backoffNanoseconds)))
                let wake = min(candidate, deadline)
                try await clock.sleep(until: wake, tolerance: .zero)
                backoffNanoseconds = min(
                    backoffNanoseconds * 2,
                    maximumBackoffNanoseconds
                )
            }
        }
    }

    private static func setLock(
        fileDescriptor: Int32,
        type: Int16,
        byte: off_t
    ) throws {
        var lock = makeLock(type: type, byte: byte)
        guard Darwin.fcntl(fileDescriptor, F_OFD_SETLK, &lock) != -1 else {
            switch errno {
            case EACCES, EAGAIN:
                throw GemmaProcessGateError.busy
            default:
                throw GemmaProcessGateError.infrastructureFailure
            }
        }
    }

    fileprivate static func observesRecordingIntent(on fileDescriptor: Int32) throws -> Bool {
        var lock = makeLock(type: Int16(F_RDLCK), byte: admissionByte)
        guard Darwin.fcntl(fileDescriptor, F_OFD_GETLK, &lock) != -1 else {
            throw GemmaProcessGateError.infrastructureFailure
        }
        return lock.l_type == Int16(F_WRLCK)
    }

    private static func makeLock(type: Int16, byte: off_t) -> flock {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = byte
        lock.l_len = 1
        return lock
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }
}

private final class GemmaProcessGateLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    var fileDescriptor: Int32 = -1

    func close() {
        let descriptor = lock.withLock {
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

    func take() -> Int32? {
        lock.withLock {
            guard fileDescriptor >= 0 else { return nil }
            let descriptor = fileDescriptor
            fileDescriptor = -1
            return descriptor
        }
    }
}
