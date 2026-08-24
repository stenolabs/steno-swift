import CryptoKit
import Foundation

public enum ModelManifestError: Error, Equatable, LocalizedError, Sendable {
    case missingFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            "Model file is missing after download: \(path)"
        }
    }
}

/// Verifies downloaded model files against committed SHA-256 checksums.
public struct ModelChecksumManifest: Sendable, Equatable, Codable {
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    public static func load(from url: URL) throws -> ModelChecksumManifest {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func verify(directory: URL) throws {
        for (relativePath, expected) in entries.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw ModelManifestError.missingFile(relativePath)
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw ModelIntegrityError.bytesDoNotMatch(
                    file: relativePath,
                    expected: expected,
                    actual: actual
                )
            }
        }
    }

    public func mismatchingFiles(directory: URL) -> [String] {
        entries.sorted { $0.key < $1.key }.compactMap { relativePath, expected in
            let url = directory.appendingPathComponent(relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == expected ? nil : relativePath
        }
    }
}
