import Darwin
import Foundation
import Synchronization

/// Serializes snapshot-sensitive library mutations across actors and Steno
/// processes that opened the same library root.
///
/// `flock` is deliberately advisory. It closes the decision boundary for all
/// cooperating in-app stores. A non-cooperating external process is outside
/// this guarantee; descriptor revalidation still fails closed for changes
/// observed before the snapshot decision's final verification.
public enum LibraryMutationCoordination {
    public static func withSharedAccess<Result>(
        layout: LibraryLayout,
        _ body: () throws -> Result
    ) throws -> Result {
        let transaction = try LibraryMutationTransaction(
            layout: layout,
            operation: LOCK_SH
        )
        defer { transaction.close() }
        return try body()
    }

    public static func withExclusiveAccess<Result>(
        layout: LibraryLayout,
        _ body: () throws -> Result
    ) throws -> Result {
        try withExclusiveTransaction(layout: layout) { _ in
            try body()
        }
    }

    package static func withExclusiveTransaction<Result>(
        layout: LibraryLayout,
        _ body: (LibraryMutationTransaction) throws -> Result
    ) throws -> Result {
        let transaction = try LibraryMutationTransaction(
            layout: layout,
            operation: LOCK_EX
        )
        defer { transaction.close() }
        return try body(transaction)
    }
}

package final class LibraryMutationTransaction: @unchecked Sendable {
    private struct State: Sendable {
        var descriptor: Int32?
    }

    private let rootPath: String
    private let deviceID: dev_t
    private let fileID: ino_t
    private let state: Mutex<State>

    fileprivate init(layout: LibraryLayout, operation: Int32) throws {
        rootPath = layout.root.standardizedFileURL.path
        let descriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open library mutation root", code: errno)
        }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXFailure(operation: "stat library mutation root", code: code)
        }
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else {
                let code = errno
                Darwin.close(descriptor)
                throw POSIXFailure(operation: "lock library mutation root", code: code)
            }
        }

        var pathStatus = stat()
        guard lstat(rootPath, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino else {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw POSIXFailure(operation: "verify library mutation root", code: ESTALE)
        }
        deviceID = descriptorStatus.st_dev
        fileID = descriptorStatus.st_ino
        state = Mutex(State(descriptor: descriptor))
    }

    deinit {
        close()
    }

    fileprivate func close() {
        let descriptor = state.withLock { state -> Int32? in
            defer { state.descriptor = nil }
            return state.descriptor
        }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    package func validate(layout: LibraryLayout) throws {
        guard layout.root.standardizedFileURL.path == rootPath else {
            throw POSIXFailure(operation: "verify library transaction root", code: EXDEV)
        }
        try state.withLock { state in
            guard let descriptor = state.descriptor else {
                throw POSIXFailure(
                    operation: "verify active library transaction",
                    code: EBADF
                )
            }
            var descriptorStatus = stat()
            var pathStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0,
                  lstat(rootPath, &pathStatus) == 0,
                  descriptorStatus.st_mode & S_IFMT == S_IFDIR,
                  pathStatus.st_mode & S_IFMT == S_IFDIR,
                  descriptorStatus.st_dev == deviceID,
                  descriptorStatus.st_ino == fileID,
                  pathStatus.st_dev == deviceID,
                  pathStatus.st_ino == fileID else {
                throw POSIXFailure(
                    operation: "verify library transaction identity",
                    code: ESTALE
                )
            }
        }
    }
}
