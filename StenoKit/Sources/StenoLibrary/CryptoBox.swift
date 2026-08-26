import CryptoKit
import Foundation

/// Storage abstraction for the library key-encryption key (KEK).
///
/// Production uses the Keychain (`KeychainKEKStore`). Tests inject an
/// in-memory store so they never touch login-keychain state.
public protocol KEKStoring: Sendable {
    func storeKEK(_ data: Data) throws
    func loadKEK() throws -> Data?
    func deleteKEK() throws
}

/// Generic-password Keychain entry holding the raw KEK bytes.
///
/// Accessibility is deliberately `AfterFirstUnlockThisDeviceOnly`: the key
/// never leaves this device and stays available for background job
/// completion shortly after boot, but not before first unlock.
public struct KeychainKEKStore: KEKStoring {
    public static let defaultService = "net.steno.stenoapp.library-encryption"
    private static let account = "library-kek"

    public let service: String

    public init(service: String = KeychainKEKStore.defaultService) {
        self.service = service
    }

    public func storeKEK(_ data: Data) throws {
        // Replace semantics: drop any previous entry first so duplicate-item
        // status can never surface as a user-visible failure.
        try? deleteKEK()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStatusError(status: status)
        }
    }

    public func loadKEK() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStatusError(status: status)
        }
        return result as? Data
    }

    public func deleteKEK() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStatusError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

public struct KeychainStatusError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Errors raised while parsing or producing the per-file ciphertext framing.
public enum CryptoBoxError: Error, Equatable, Sendable {
    case framingTooShort(byteCount: Int)
    case unknownMagic
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unsupportedAlgorithm(found: UInt16)
    case authenticationFailure
}

/// File-level AEAD box for the encryption-at-rest beta.
///
/// Framing of one encrypted file (all integers little-endian):
///
/// ```
/// offset   0   8 bytes  magic "STENCBX1"
/// offset   8   uint32   schemaVersion (currently 1)
/// offset  12   uint16   algorithm identifier (1 = AES-256-GCM)
/// offset  14   12 bytes wrap nonce (DEK sealed by KEK)
/// offset  26   48 bytes wrapped DEK (32-byte ciphertext + 16-byte tag)
/// offset  74   12 bytes content nonce
/// offset  86   N bytes  payload ciphertext + 16-byte tag
/// ```
///
/// Every file carries a freshly generated random content-encryption key
/// (DEK). The DEK itself is sealed with the library KEK, so per-file key
/// isolation never weakens neighbouring files. Both AEAD operations
/// authenticate the fixed header prefix as associated data, meaning any
/// tampering with magic, version, algorithm, or wrapped key breaks
/// decryption.
public enum CryptoBox {
    public static let schemaVersion = 1
    public static let algorithmIdentifierAES256GCM: UInt16 = 1

    static let magic = Data("STENCBX1".utf8)

    private static let gcmTagLength = 16
    private static let wrapNonceRange = 14..<26
    private static let wrappedKeyCiphertextRange = 26..<58
    private static let wrappedKeyTagRange = 58..<74
    private static let contentNonceRange = 74..<86
    static let fixedHeaderLength = 86

    /// True when `data` starts with this implementation's magic marker.
    public static func isEncryptedFile(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    /// Seals `plaintext` into the framed wire format described above.
    public static func encrypt(
        _ plaintext: Data,
        keyEncryptionKey: Data
    ) throws -> Data {
        let dek = SymmetricKey(size: .bits256)
        let framePrefix = Self.framePrefixData

        let wrapNonce = AES.GCM.Nonce()
        let wrappedKey = try AES.GCM.seal(
            dek.withUnsafeBytes { Data($0) },
            using: SymmetricKey(data: keyEncryptionKey),
            nonce: wrapNonce,
            authenticating: framePrefix
        )

        var output = framePrefix
        output.append(Data(wrapNonce))
        output.append(wrappedKey.ciphertext)
        output.append(wrappedKey.tag)

        let contentNonce = AES.GCM.Nonce()
        // The content AEAD authenticates everything up to (not including)
        // its own nonce; the nonce itself is stored unauthenticated in the
        // clear, as GCM intends.
        let sealedContent = try AES.GCM.seal(
            plaintext,
            using: dek,
            nonce: contentNonce,
            authenticating: output
        )
        output.append(Data(contentNonce))
        output.append(sealedContent.ciphertext)
        output.append(sealedContent.tag)
        return output
    }

    /// Opens a framed blob produced by `encrypt`.
    ///
    /// Throws `authenticationFailure` when the KEK is wrong or any
    /// authenticated byte (header prefix or payload) was modified.
    public static func decrypt(
        _ framed: Data,
        keyEncryptionKey: Data
    ) throws -> Data {
        guard framed.count >= fixedHeaderLength + gcmTagLength else {
            throw CryptoBoxError.framingTooShort(byteCount: framed.count)
        }
        guard framed.starts(with: magic) else {
            throw CryptoBoxError.unknownMagic
        }

        let version = readUInt32LE(framed, offset: 8)
        guard version == schemaVersion else {
            throw CryptoBoxError.unsupportedSchemaVersion(
                found: version,
                supported: schemaVersion
            )
        }
        let algorithm = readUInt16LE(framed, offset: 12)
        guard algorithm == algorithmIdentifierAES256GCM else {
            throw CryptoBoxError.unsupportedAlgorithm(found: algorithm)
        }

        let framePrefix = framed.prefix(framePrefixData.count)
        let wrappedBox: AES.GCM.SealedBox
        let dekData: Data
        do {
            wrappedBox = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: framed.subdata(in: wrapNonceRange)),
                ciphertext: framed.subdata(in: wrappedKeyCiphertextRange),
                tag: framed.subdata(in: wrappedKeyTagRange)
            )
            dekData = try AES.GCM.open(
                wrappedBox,
                using: SymmetricKey(data: keyEncryptionKey),
                authenticating: Data(framePrefix)
            )
        } catch {
            // Wrong KEK or tampered wrapped key.
            throw CryptoBoxError.authenticationFailure
        }

        let contentStart = fixedHeaderLength
        let contentEnd = framed.count - gcmTagLength
        guard contentEnd >= contentStart else {
            throw CryptoBoxError.framingTooShort(byteCount: framed.count)
        }
        let contentBox: AES.GCM.SealedBox
        do {
            contentBox = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: framed.subdata(in: contentNonceRange)),
                ciphertext: framed.subdata(in: contentStart..<contentEnd),
                tag: framed.subdata(in: contentEnd..<framed.count)
            )
            // Content AEAD authenticates the header through the wrapped
            // key, mirroring `encrypt`.
            return try AES.GCM.open(
                contentBox,
                using: SymmetricKey(data: dekData),
                authenticating: framed.prefix(wrappedKeyTagRange.upperBound)
            )
        } catch {
            // Tampered payload or framing.
            throw CryptoBoxError.authenticationFailure
        }
    }

    /// Generates fresh uniform key material (KEK, salts, backup entropy).
    public static func generateKeyData(byteCount: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
            .withUnsafeBytes { Data($0) }
    }

    private static var framePrefixData: Data {
        var data = magic
        appendUInt32LE(schemaVersion, to: &data)
        appendUInt16LE(algorithmIdentifierAES256GCM, to: &data)
        return data
    }
}

// MARK: - Little-endian integer helpers

private func appendUInt32LE(_ value: Int, to data: inout Data) {
    withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func readUInt32LE(_ data: Data, offset: Int) -> Int {
    let chunk = data.subdata(in: offset..<offset + 4)
    return chunk.withUnsafeBytes {
        Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
    }
}

private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    let chunk = data.subdata(in: offset..<offset + 2)
    return chunk.withUnsafeBytes {
        UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
    }
}
