import Foundation

/// Filesystem facade over a user-chosen Obsidian vault folder.
///
/// The vault is a plain directory the user owns; Obsidian (or any other
/// editor) may hold the same files open at any time. Everything here is
/// therefore deliberately small and non-destructive: writes are atomic, and
/// nothing ever deletes. Deleting in the vault never touches the library —
/// this type has no API that could even express that direction, because the
/// sync is one-way by contract.
public struct ObsidianVault: Sendable {
    /// Folder chosen by the user. Only files directly inside are managed;
    /// subfolders (the user's own vault structure) are never touched.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Names of Markdown files directly in the vault root, sorted for
    /// deterministic collision probing. Unreadable directories yield an
    /// empty list: a missing folder is treated as "nothing mirrored yet",
    /// not as an error — the first export creates the folder implicitly via
    /// the atomic write.
    public func markdownFileNames() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".md") }
            .sorted()
    }

    /// Contents of one vault file, or nil when it does not exist or cannot
    /// be read (locked, cloud-evicted). Nil is the honest answer for "we
    /// cannot know what is in there".
    public func contents(fileName: String) -> String? {
        guard Self.isSafeFileName(fileName) else { return nil }
        return try? String(
            contentsOf: baseURL.appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    /// Atomically writes one Markdown file into the vault root.
    @discardableResult
    public func write(_ text: String, fileName: String) throws -> URL {
        guard Self.isSafeFileName(fileName) else {
            throw ObsidianVaultError.unsafeFileName(fileName)
        }
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true
        )
        let url = baseURL.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Renames an already-mirrored file (title or date changed between
    /// exports). Fails loudly if the destination exists: the caller probes
    /// for a free name first and must never clobber another note.
    public func rename(from source: String, to destination: String) throws {
        guard Self.isSafeFileName(source), Self.isSafeFileName(destination) else {
            throw ObsidianVaultError.unsafeFileName("\(source) -> \(destination)")
        }
        let sourceURL = baseURL.appendingPathComponent(source)
        let destinationURL = baseURL.appendingPathComponent(destination)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ObsidianVaultError.sourceMissing(source)
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ObsidianVaultError.destinationExists(destination)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    /// A name may only ever address a file directly inside the vault root:
    /// no separators, no traversal, no dot names.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "." && name != ".."
            && !name.contains("/")
            && !name.contains(":")
    }
}

public enum ObsidianVaultError: LocalizedError, Equatable, Sendable {
    case unsafeFileName(String)
    case sourceMissing(String)
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeFileName(let name):
            "Refusing to touch the unsafe file name “\(name)”."
        case .sourceMissing(let name):
            "The mirrored file “\(name)” has disappeared from the vault."
        case .destinationExists(let name):
            "A file named “\(name)” already exists in the vault."
        }
    }
}
