import CryptoKit
import Darwin
import Foundation

enum MeetingTransferFileDigestError: Error, Sendable {
    case readFailed
    case byteCountMismatch
}

public enum MeetingTransferDigest {
    public static let fileReadChunkSize = 1_024 * 1_024

    public static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: fileReadChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package static func sha256(
        fileDescriptor: Int32,
        expectedByteCount: Int64
    ) throws -> String {
        guard expectedByteCount >= 0 else {
            throw MeetingTransferFileDigestError.byteCountMismatch
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: fileReadChunkSize)
        while offset < expectedByteCount {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.count), expectedByteCount - offset))
            let count: Int
            while true {
                let result = buffer.withUnsafeMutableBytes {
                    pread(fileDescriptor, $0.baseAddress, wanted, off_t(offset))
                }
                if result >= 0 {
                    count = result
                    break
                }
                if errno != EINTR {
                    throw MeetingTransferFileDigestError.readFailed
                }
            }
            guard count > 0 else {
                throw MeetingTransferFileDigestError.byteCountMismatch
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count])
                )
            }
            offset += Int64(count)
        }
        var sentinel: UInt8 = 0
        let extra: Int
        while true {
            let result = pread(fileDescriptor, &sentinel, 1, off_t(expectedByteCount))
            if result >= 0 {
                extra = result
                break
            }
            if errno != EINTR {
                throw MeetingTransferFileDigestError.readFailed
            }
        }
        guard extra == 0 else {
            throw MeetingTransferFileDigestError.byteCountMismatch
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func contentDigest(for entries: [MeetingTransferManifest.Entry]) throws -> String {
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            update(&hasher, value: Data(entry.path.utf8))
            update(&hasher, value: Data(String(entry.byteCount).utf8))
            update(&hasher, value: Data(entry.sha256.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, value: Data) {
        var byteCount = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &byteCount) { hasher.update(bufferPointer: $0) }
        hasher.update(data: value)
    }
}
