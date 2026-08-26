import CryptoKit
import Foundation

/// Direction of a staged library conversion.
public enum LibraryEncryptionOperation: String, Sendable {
    /// Plain library -> encrypted copy. Backup suffix: `.plain.bak`.
    case encryption
    /// Encrypted library -> plain copy (disable). Backup suffix:
    /// `.encrypted.bak`.
    case decryption
}

/// Canonical file-system locations used by the encryption beta.
///
/// Everything lives NEXT TO the active library root so that the recursive
/// file walk only ever sees files inside the root and never has to filter
/// staging or backup directories out of the tree it copies.
public enum LibraryEncryptionLocation {
    public static let headerFileName = "encryption-header.json"

    /// Marks an encrypted library; absent on a plain one.
    public static func headerURL(root: URL) -> URL {
        root.appendingPathComponent(headerFileName)
    }

    public static func stagingURL(
        root: URL,
        operation: LibraryEncryptionOperation
    ) -> URL {
        root.appendingPathExtension("\(operation.rawValue)-staging")
    }

    public static func backupURL(
        root: URL,
        operation: LibraryEncryptionOperation
    ) -> URL {
        switch operation {
        case .encryption: return root.appendingPathExtension("plain.bak")
        case .decryption: return root.appendingPathExtension("encrypted.bak")
        }
    }
}

/// KEK backup blob parameters stored INSIDE the encrypted library.
///
/// The backup blob is the KEK sealed with a key derived from the user's
/// recovery code via HKDF-SHA256. Because the blob travels with the
/// library, the code alone - without any Keychain entry - can re-derive
/// the KEK on this or any future machine.
public struct LibraryKeyBackup: Codable, Equatable, Sendable {
    public var kdfIdentifier: String
    public var kdfInfo: Data
    public var salt: Data
    public var nonce: Data
    public var ciphertextAndTag: Data

    public init(
        kdfIdentifier: String,
        kdfInfo: Data,
        salt: Data,
        nonce: Data,
        ciphertextAndTag: Data
    ) {
        self.kdfIdentifier = kdfIdentifier
        self.kdfInfo = kdfInfo
        self.salt = salt
        self.nonce = nonce
        self.ciphertextAndTag = ciphertextAndTag
    }
}

/// Library-level encryption header document (`encryption-header.json`).
public struct LibraryEncryptionHeader: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let cipherIdentifier = "AES-256-GCM"
    public static let kdfIdentifierHKDFSHA256 = "HKDF-SHA256"
    static let kekBackupAAD = Data("net.steno.kek-backup.v1".utf8)

    public var schemaVersion: Int
    public var createdAt: Date
    public var cipherIdentifier: String
    public var keyBackup: LibraryKeyBackup
    public var encryptedFileCount: Int

    public init(
        schemaVersion: Int,
        createdAt: Date,
        cipherIdentifier: String,
        keyBackup: LibraryKeyBackup,
        encryptedFileCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.cipherIdentifier = cipherIdentifier
        self.keyBackup = keyBackup
        self.encryptedFileCount = encryptedFileCount
    }
}

// MARK: - Persistence

extension LibraryEncryptionHeader {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Loads the header from `root`, returning nil for a plain library.
    public static func loadIfPresent(root: URL) throws -> Self? {
        let url = LibraryEncryptionLocation.headerURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try makeDecoder().decode(
                Self.self,
                from: Data(contentsOf: url)
            )
        } catch let error as DecodingError {
            throw LibraryEncryptionError.headerCorrupt(url, detail: "\(error)")
        } catch {
            throw LibraryEncryptionError.headerCorrupt(
                url,
                detail: String(describing: error)
            )
        }
    }

    /// Validates the loaded version and writes the header into a staging
    /// directory atomically.
    public func write(to url: URL) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LibraryEncryptionError.unsupportedHeaderSchemaVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try AtomicFile.write(
            try Self.makeEncoder().encode(self),
            to: url
        )
    }

    /// Raw bytes as persisted, used by callers to prove an operation left
    /// the header untouched.
    public static func rawData(root: URL) throws -> Data {
        try Data(contentsOf: LibraryEncryptionLocation.headerURL(root: root))
    }
}

// MARK: - Key backup creation and unwrapping

extension LibraryEncryptionHeader {
    /// HKDF-SHA256 over the decoded recovery-code characters.
    static func recoveryKey(
        code: RecoveryCode,
        salt: Data,
        info: Data
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: code.keyMaterial),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Builds a complete header with a freshly generated KEK backup blob.
    ///
    /// Called during `prepareEncryption`; the returned header lands in the
    /// staged copy together with the encrypted files.
    public static func create(
        keyEncryptionKey: Data,
        recoveryCode: RecoveryCode,
        encryptedFileCount: Int,
        now: Date = Date()
    ) throws -> Self {
        let salt = CryptoBox.generateKeyData(byteCount: 32)
        let info = Data("net.steno.library-encryption.kek-backup.v1".utf8)
        let sealNonce = AES.GCM.Nonce()
        let sealedKEK = try AES.GCM.seal(
            keyEncryptionKey,
            using: Self.recoveryKey(code: recoveryCode, salt: salt, info: info),
            nonce: sealNonce,
            authenticating: kekBackupAAD
        )
        return Self(
            schemaVersion: currentSchemaVersion,
            createdAt: now,
            cipherIdentifier: cipherIdentifier,
            keyBackup: LibraryKeyBackup(
                kdfIdentifier: kdfIdentifierHKDFSHA256,
                kdfInfo: info,
                salt: salt,
                nonce: Data(sealNonce),
                ciphertextAndTag: sealedKEK.ciphertext + sealedKEK.tag
            ),
            encryptedFileCount: encryptedFileCount
        )
    }

    /// Recovers the raw KEK from the in-library backup blob using nothing
    public func unwrapKEK(using code: RecoveryCode) throws -> Data {
        guard keyBackup.kdfIdentifier == Self.kdfIdentifierHKDFSHA256 else {
            throw LibraryEncryptionError.unsupportedHeaderSchemaVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        // `ciphertextAndTag` stores ONLY ciphertext + tag (the nonce has
        // its own field), so the box cannot use the combined initializer.
        let tagLength = 16
        guard keyBackup.ciphertextAndTag.count > tagLength else {
            throw LibraryEncryptionError.kekBackupCorrupt
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: keyBackup.nonce),
                ciphertext: keyBackup.ciphertextAndTag.prefix(
                    keyBackup.ciphertextAndTag.count - tagLength
                ),
                tag: keyBackup.ciphertextAndTag.suffix(tagLength)
            )
        } catch {
            throw LibraryEncryptionError.kekBackupCorrupt
        }
        do {
            return try AES.GCM.open(
                box,
                using: Self.recoveryKey(
                    code: code,
                    salt: keyBackup.salt,
                    info: keyBackup.kdfInfo
                ),
                authenticating: Self.kekBackupAAD
            )
        } catch {
            throw LibraryEncryptionError.recoveryCodeWrong
        }
    }
}
