import Darwin
import Foundation

public enum AtomicFile {
    struct PreparedWrite: Sendable {
        let temporaryURL: URL
        let destinationURL: URL

        func commit() throws {
            let result = temporaryURL.path.withCString { temporaryPath in
                destinationURL.path.withCString { destinationPath in
                    Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard result == 0 else {
                throw POSIXFailure(operation: "rename", code: errno)
            }

            try AtomicFile.synchronizeDirectory(
                destinationURL.deletingLastPathComponent()
            )
        }

        /// Publishes a prepared append-only document without replacing an
        /// existing destination. Returns false only when another writer won
        /// the same destination race.
        func commitWithoutReplacing() throws -> Bool {
            let parentURL = destinationURL.deletingLastPathComponent()
            guard temporaryURL.deletingLastPathComponent() == parentURL else {
                throw POSIXFailure(operation: "rename no-replace parent mismatch", code: EINVAL)
            }
            let parentDescriptor = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard parentDescriptor >= 0 else {
                throw POSIXFailure(operation: "open rename parent", code: errno)
            }
            defer { Darwin.close(parentDescriptor) }

            let result = renameatx_np(
                parentDescriptor,
                temporaryURL.lastPathComponent,
                parentDescriptor,
                destinationURL.lastPathComponent,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
            )
            if result != 0, errno == EEXIST {
                try? FileManager.default.removeItem(at: temporaryURL)
                return false
            }
            guard result == 0 else {
                throw POSIXFailure(operation: "rename no-replace", code: errno)
            }
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw POSIXFailure(operation: "fsync directory", code: errno)
            }
            return true
        }
    }

    public static func write(_ data: Data, to destinationURL: URL) throws {
        let prepared = try prepare(data, to: destinationURL)
        do {
            try prepared.commit()
        } catch {
            try? FileManager.default.removeItem(at: prepared.temporaryURL)
            throw error
        }
    }

    static func prepare(_ data: Data, to destinationURL: URL) throws -> PreparedWrite {
        let parent = destinationURL.deletingLastPathComponent()
        let temporaryURL = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open", code: errno)
        }

        do {
            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXFailure(operation: "fsync", code: errno)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw POSIXFailure(operation: "close", code: errno)
            }
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return PreparedWrite(
            temporaryURL: temporaryURL,
            destinationURL: destinationURL
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXFailure(operation: "write", code: errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXFailure(operation: "fsync directory", code: errno)
        }
    }
}

public struct POSIXFailure: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}
