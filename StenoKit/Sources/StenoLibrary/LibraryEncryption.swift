import CryptoKit
import Foundation

/// Coarse-grained progress for long-running staging operations.
public struct EncryptionProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Reading source files and writing the staged copy.
        case transferring
        /// Decrypt-and-compare verification of the staged copy.
        case verifying
    }

    public let phase: EncryptionProgress.Phase
    public let processedFiles: Int
    public let totalFiles: Int

    public init(phase: EncryptionProgress.Phase, processedFiles: Int, totalFiles: Int) {
        self.phase = phase
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
    }
}

/// Point-in-time projection of the encryption state machine.
///
/// - `isEncrypted`: an encryption header is present at the active root.
/// - `pendingOperation`: a fully written but not yet activated staging
///   directory exists (a previous run prepared but never activated).
/// - `backupExists`: a pre-switch backup of the old library is waiting for
///   explicit deletion by the user.
public struct EncryptionStatus: Sendable, Equatable {
    public let isEncrypted: Bool
    public let pendingOperation: LibraryEncryptionOperation?
    public let backupExists: Bool
}

/// Handle to a completed staging run awaiting `activateStaged()`.
public struct StagedCopy: Sendable {
    public let operation: LibraryEncryptionOperation
    public let directoryURL: URL
    public let fileCount: Int
    /// Fresh recovery code for the KEK backup blob written into the staged
    /// header. Only produced by the encryption direction; the UI MUST show
    /// it to the user before activation (the code is unrecoverable later).
    public let recoveryCode: RecoveryCode?
}

public enum LibraryEncryptionError: Error, Equatable, Sendable, LocalizedError {
    case libraryRootMissing(URL)
    case alreadyEncrypted
    case notEncrypted
    case noStagedOperation
    case staleStagingFound(URL)
    case backupAlreadyExists(URL)
    case headerMissing(URL)
    case headerCorrupt(URL, detail: String)
    case kekBackupCorrupt
    case unsupportedHeaderSchemaVersion(found: Int, supported: Int)
    case recoveryCodeWrong
    case verificationMismatch(relativePath: String)
    case kekUnavailable

    public var errorDescription: String? {
        switch self {
        case .libraryRootMissing(let url):
            return "Library directory does not exist: \(url.path)."
        case .alreadyEncrypted:
            return "The library is already encrypted."
        case .notEncrypted:
            return "The library is not encrypted."
        case .noStagedOperation:
            return "There is no staged copy to activate."
        case .kekUnavailable:
            return
                "The library key is unavailable; recover it with your recovery code first."
        case .staleStagingFound(let url):
            return
                "A previous staging run was left behind at \(url.path). Cancel it first."
        case .backupAlreadyExists(let url):
            return
                "A pre-switch backup already exists at \(url.path); delete it explicitly before switching again."
        case .headerMissing(let url):
            return "Encryption header is missing: \(url.path)."
        case .headerCorrupt(let url, let detail):
            return "Encryption header is corrupt: \(url.path) (\(detail))."
        case .kekBackupCorrupt:
            return "The KEK backup blob inside the header is malformed."
        case .unsupportedHeaderSchemaVersion(let found, let supported):
            return
                "Encryption header schema version \(found) is unsupported; supported: \(supported)."
        case .recoveryCodeWrong:
            return "The recovery code does not match this library."
        case .verificationMismatch(let relativePath):
            return
                "Verification failed: decrypted copy of \(relativePath) differs from the original."
        }
    }
}

/// Coordinator for the library-encryption beta (ARCHITECTURE.md section 8).
///
/// Invariants, in order of importance:
///
/// 1. **Never in place.** Every operation (`prepareEncryption`,
///    `prepareDecryption`) writes a COMPLETE converted copy into a staging
///    directory next to the active root before anything is touched.
/// 2. **Verify before switch.** The staged copy is decrypted again and
///    compared against the source (full SHA-256 for every file plus direct
///    byte comparison of a deterministic sample including the largest
///    file). Activation only ever happens on verified output.
/// 3. **Atomic switch, kept backup.** Activation renames the old root to
///    `.plain.bak` / `.encrypted.bak` and then renames staging into place.
///    The backup is never deleted implicitly; the user deletes it
///    explicitly via `deleteBackup(_:)` once satisfied.
/// 4. **No partial states.** A crash before activation leaves the original
///    library untouched plus a removable staging directory; `cancel()`
///    clears it. A crash between the two activation renames leaves the
///    root missing while the complete backup sits beside it;
///    `recoverInterruptedSwitch(root:)` restores it deterministically and
///    is intended to be wired into startup validation.
///
/// Key hierarchy: random 256-bit DEK per file, wrapped by one library KEK.
/// The KEK lives in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
/// AND as a backup blob inside the library header sealed with a key
/// derived from the user's base32 recovery code, so the code alone can
/// unwrap every file even after Keychain loss.
public actor LibraryEncryptionCoordinator {
    public let layout: LibraryLayout
    private let keyStore: any KEKStoring

    public init(layout: LibraryLayout, keyStore: any KEKStoring = KeychainKEKStore()) {
        self.layout = layout
        self.keyStore = keyStore
    }

    // MARK: Status

    public func status() -> EncryptionStatus {
        let root = layout.root
        let isEncrypted = FileManager.default.fileExists(
            atPath: LibraryEncryptionLocation.headerURL(root: root).path
        )
        let pending =
            fileExists(LibraryEncryptionLocation.stagingURL(root: root, operation: .encryption))
            ? LibraryEncryptionOperation.encryption
            : fileExists(LibraryEncryptionLocation.stagingURL(root: root, operation: .decryption))
            ? LibraryEncryptionOperation.decryption
            : nil
        let backupExists =
            fileExists(LibraryEncryptionLocation.backupURL(root: root, operation: .encryption))
            || fileExists(LibraryEncryptionLocation.backupURL(root: root, operation: .decryption))
        return EncryptionStatus(
            isEncrypted: isEncrypted,
            pendingOperation: pending,
            backupExists: backupExists
        )
    }

    // MARK: Enable

    /// Builds a complete encrypted copy of the library in a staging
    /// directory and verifies it by full decrypt-and-compare.
    ///
    /// Generates the library KEK on first use (stored via `keyStore`) and a
    /// fresh recovery code whose backup blob lands in the staged header.
    /// Returns the staged handle; nothing at the active root changes until
    /// `activateStaged()` runs.
    @discardableResult
    public func prepareEncryption(
        progress: (@Sendable (EncryptionProgress) -> Void)? = nil
    ) throws -> StagedCopy {
        let root = try validatedActiveRoot()
        guard try LibraryEncryptionHeader.loadIfPresent(root: root) == nil else {
            throw LibraryEncryptionError.alreadyEncrypted
        }
        let staging = LibraryEncryptionLocation.stagingURL(root: root, operation: .encryption)
        try rejectStaleStaging(staging)
        try removeDirectoryIfPresent(staging)

        let kek = try loadOrCreateKEK()
        let recoveryCode = RecoveryCode.generate()

        let sources = try enumerateRegularFiles(in: root)
        var digests: [String: Data] = [:]
        digests.reserveCapacity(sources.count)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for (index, source) in sources.enumerated() {
            let relativePath = try relativePath(of: source, under: root)
            let plaintext = try Data(contentsOf: source)
            digests[relativePath] = Data(SHA256.hash(data: plaintext))
            let framed = try CryptoBox.encrypt(plaintext, keyEncryptionKey: kek)
            try write(data: framed, relativePath: relativePath, stagingRoot: staging)
            progress?(EncryptionProgress(
                phase: .transferring,
                processedFiles: index + 1,
                totalFiles: sources.count
            ))
        }

        try verifyStagedCopy(
            staging: staging,
            sources: sources,
            digests: digests,
            kek: kek,
            stagedFilesAreEncrypted: true,
            progress: progress
        )

        let header = try LibraryEncryptionHeader.create(
            keyEncryptionKey: kek,
            recoveryCode: recoveryCode,
            encryptedFileCount: sources.count
        )
        try header.write(to: LibraryEncryptionLocation.headerURL(root: staging))
        try AtomicFile.synchronizeDirectory(staging)

        return StagedCopy(
            operation: .encryption,
            directoryURL: staging,
            fileCount: sources.count,
            recoveryCode: recoveryCode
        )
    }

    // MARK: Disable

    /// Builds a complete decrypted copy of the library in a staging
    /// directory and verifies it against the encrypted originals.
    ///
    /// Requires the KEK; if the Keychain entry was lost, call
    /// `decryptWithRecoveryCode(_:)` first.
    @discardableResult
    public func prepareDecryption(
        progress: (@Sendable (EncryptionProgress) -> Void)? = nil
    ) throws -> StagedCopy {
        let root = try validatedActiveRoot()
        guard try LibraryEncryptionHeader.loadIfPresent(root: root) != nil else {
            throw LibraryEncryptionError.notEncrypted
        }
        let staging = LibraryEncryptionLocation.stagingURL(root: root, operation: .decryption)
        try rejectStaleStaging(staging)
        try removeDirectoryIfPresent(staging)

        guard let kek = try keyStore.loadKEK() else {
            throw LibraryEncryptionError.kekUnavailable
        }

        let sources = try enumerateRegularFiles(in: root, excludingHeaderAt: root)
        var digests: [String: Data] = [:]
        digests.reserveCapacity(sources.count)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for (index, source) in sources.enumerated() {
            let relativePath = try relativePath(of: source, under: root)
            let framed = try Data(contentsOf: source)
            let plaintext: Data
            do {
                plaintext = try CryptoBox.decrypt(framed, keyEncryptionKey: kek)
            } catch {
                throw LibraryEncryptionError.verificationMismatch(relativePath: relativePath)
            }
            digests[relativePath] = Data(SHA256.hash(data: plaintext))
            try write(data: plaintext, relativePath: relativePath, stagingRoot: staging)
            progress?(EncryptionProgress(
                phase: .transferring,
                processedFiles: index + 1,
                totalFiles: sources.count
            ))
        }

        try verifyStagedCopy(
            staging: staging,
            sources: sources,
            digests: digests,
            kek: kek,
            stagedFilesAreEncrypted: false,
            progress: progress
        )
        try AtomicFile.synchronizeDirectory(staging)

        return StagedCopy(
            operation: .decryption,
            directoryURL: staging,
            fileCount: sources.count,
            recoveryCode: nil
        )
    }

    // MARK: Activation

    /// Atomically replaces the active library with the previously staged,
    /// verified copy. The old library survives under its backup suffix
    /// until explicitly deleted via `deleteBackup(_:)`.
    ///
    /// Crash safety: if the process dies between the two renames, the root
    /// is missing while the complete backup remains; startup calls
    /// `recoverInterruptedSwitch(root:)` to restore it.
    public func activateStaged() throws {
        let root = layout.root
        let parent = root.deletingLastPathComponent()

        let operation: LibraryEncryptionOperation
        if fileExists(LibraryEncryptionLocation.stagingURL(root: root, operation: .encryption)) {
            operation = .encryption
        } else if fileExists(LibraryEncryptionLocation.stagingURL(root: root, operation: .decryption)) {
            operation = .decryption
        } else {
            throw LibraryEncryptionError.noStagedOperation
        }

        let backup = LibraryEncryptionLocation.backupURL(root: root, operation: operation)
        guard !fileExists(backup) else {
            throw LibraryEncryptionError.backupAlreadyExists(backup)
        }
        guard fileExists(root) else {
            throw LibraryEncryptionError.libraryRootMissing(root)
        }

        do {
            try AtomicFile.synchronizeDirectory(parent)
            try FileManager.default.moveItem(at: root, to: backup)
        } catch {
            throw LibraryEncryptionError.verificationMismatch(relativePath: "activation/backup-rename")
        }
        do {
            try FileManager.default.moveItem(
                at: LibraryEncryptionLocation.stagingURL(root: root, operation: operation),
                to: root
            )
            try AtomicFile.synchronizeDirectory(parent)
        } catch {
            // Roll back so the user never faces a missing library.
            if !fileExists(root), fileExists(backup) {
                try? FileManager.default.moveItem(at: backup, to: root)
            }
            throw LibraryEncryptionError.verificationMismatch(relativePath: "activation/staging-rename")
        }
    }

    /// Removes any leftover staging directories. Safe to call at any time;
    /// the active library and any backup are never touched.
    public func cancel() {
        for operation in [LibraryEncryptionOperation.encryption, .decryption] {
            try? FileManager.default.removeItem(
                at: LibraryEncryptionLocation.stagingURL(root: layout.root, operation: operation)
            )
        }
    }

    /// Explicitly removes the post-switch backup of the old library. This
    /// is the ONLY deletion path; nothing here destroys backups silently.
    public func deleteBackup(_ operation: LibraryEncryptionOperation) throws {
        try FileManager.default.removeItem(
            at: LibraryEncryptionLocation.backupURL(root: layout.root, operation: operation)
        )
    }

    // MARK: Recovery

    /// Recovers the KEK purely from the human recovery code and the
    /// backup blob stored inside the library header - no Keychain entry
    /// required - and reinstates it via `keyStore`.
    ///
    /// Throws `recoveryCodeWrong` for a well-formed but incorrect code;
    /// malformed codes are rejected by `RecoveryCode.init` itself. No
    /// library byte is modified on failure.
    public func decryptWithRecoveryCode(_ code: RecoveryCode) throws {
        let root = layout.root
        guard let header = try LibraryEncryptionHeader.loadIfPresent(root: root) else {
            throw LibraryEncryptionError.headerMissing(
                LibraryEncryptionLocation.headerURL(root: root)
            )
        }
        let kek = try header.unwrapKEK(using: code)
        try keyStore.storeKEK(kek)
    }

    /// Restores the active root after a crash between the two activation
    /// renames (root missing, complete backup present). Returns true when
    /// a restoration happened. Wire into startup validation BEFORE opening
    /// stores so a half-switched library can never be observed.
    public nonisolated static func recoverInterruptedSwitch(root: URL) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: root.path) else { return false }
        for operation in [LibraryEncryptionOperation.encryption, .decryption] {
            let backup = LibraryEncryptionLocation.backupURL(root: root, operation: operation)
            guard fileManager.fileExists(atPath: backup.path) else { continue }
            do {
                try fileManager.moveItem(at: backup, to: root)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: Internals

    private func validatedActiveRoot() throws -> URL {
        let root = layout.root
        guard fileExists(root) else {
            throw LibraryEncryptionError.libraryRootMissing(root)
        }
        return root
    }

    private func rejectStaleStaging(_ staging: URL) throws {
        if fileExists(staging) {
            throw LibraryEncryptionError.staleStagingFound(staging)
        }
        for other in [LibraryEncryptionOperation.encryption, .decryption] {
            let url = LibraryEncryptionLocation.stagingURL(root: layout.root, operation: other)
            if fileExists(url) {
                throw LibraryEncryptionError.staleStagingFound(url)
            }
        }
    }

    private func loadOrCreateKEK() throws -> Data {
        if let existing = try keyStore.loadKEK() { return existing }
        let generated = CryptoBox.generateKeyData(byteCount: 32)
        try keyStore.storeKEK(generated)
        return generated
    }

    /// Full-hash verification of every staged file plus direct byte
    /// comparison of a deterministic sample that always includes the
    /// largest transferred file.
    private func verifyStagedCopy(
        staging: URL,
        sources: [URL],
        digests: [String: Data],
        kek: Data,
        stagedFilesAreEncrypted: Bool,
        progress: (@Sendable (EncryptionProgress) -> Void)?
    ) throws {
        let root = layout.root
        let orderedRelativePaths = digests.keys.sorted()
        for (index, relativePath) in orderedRelativePaths.enumerated() {
            let staged = try Data(contentsOf: staging.appendingPathComponent(relativePath))
            let verified: Data
            if stagedFilesAreEncrypted {
                do {
                    verified = try CryptoBox.decrypt(staged, keyEncryptionKey: kek)
                } catch {
                    throw LibraryEncryptionError.verificationMismatch(relativePath: relativePath)
                }
            } else {
                // Decryption direction: the staged copy is already plain.
                verified = staged
            }
            guard Data(SHA256.hash(data: verified)) == digests[relativePath] else {
                throw LibraryEncryptionError.verificationMismatch(relativePath: relativePath)
            }
            progress?(EncryptionProgress(
                phase: .verifying,
                processedFiles: index + 1,
                totalFiles: orderedRelativePaths.count
            ))
        }

        // Byte-level spot checks: up to five evenly spaced files plus the
        // largest source file, compared directly against the originals.
        var sampleIndices = Set<Int>()
        if !sources.isEmpty {
            let sampleCount = min(5, sources.count)
            for offset in 0..<sampleCount {
                sampleIndices.insert(offset * sources.count / sampleCount)
            }
            if let largestIndex = sources.indices.max(by: {
                fileSize(sources[$0]) ?? 0 < fileSize(sources[$1]) ?? 0
            }) {
                sampleIndices.insert(largestIndex)
            }
        }
        for index in sampleIndices.sorted() {
            let source = sources[index]
            let relativePath = try relativePath(of: source, under: root)
            let staged = try Data(contentsOf: staging.appendingPathComponent(relativePath))
            if stagedFilesAreEncrypted {
                // Encryption direction: the source is plaintext, so the
                // decrypted staged bytes must equal it byte for byte.
                let candidate = try CryptoBox.decrypt(staged, keyEncryptionKey: kek)
                let original = try Data(contentsOf: source)
                guard candidate == original else {
                    throw LibraryEncryptionError.verificationMismatch(relativePath: relativePath)
                }
            } else {
                // Decryption direction: the source is ciphertext; compare
                // against the digest recorded during transfer instead.
                guard Data(SHA256.hash(data: staged)) == digests[relativePath] else {
                    throw LibraryEncryptionError.verificationMismatch(relativePath: relativePath)
                }
            }
        }
    }

    private func enumerateRegularFiles(
        in directory: URL,
        excludingHeaderAt root: URL? = nil
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        guard let enumerator else {
            throw LibraryEncryptionError.libraryRootMissing(directory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            // Hidden files are editor/.DS_Store noise or AtomicFile tmp
            // leftovers; none of them belong in a verified copy.
            if url.lastPathComponent.hasPrefix(".") { continue }
            // The enumerator resolves symlinks in returned URLs, so a raw
            // URL comparison against `root` can miss; compare standardized
            // paths instead.
            if let root,
                url.standardizedFileURL.path
                    == LibraryEncryptionLocation.headerURL(root: root)
                    .standardizedFileURL.path
            { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }

    private func write(
        data: Data,
        relativePath: String,
        stagingRoot: URL
    ) throws {
        let destination = stagingRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFile.write(data, to: destination)
    }

    private func removeDirectoryIfPresent(_ url: URL) throws {
        if fileExists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let standardized = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/") else {
            throw LibraryEncryptionError.libraryRootMissing(root)
        }
        return String(standardized.dropFirst(rootPath.count + 1))
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
