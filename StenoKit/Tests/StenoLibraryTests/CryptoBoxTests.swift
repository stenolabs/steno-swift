import CryptoKit
import Foundation
import Testing
@testable import StenoLibrary

@Suite("CryptoBox")
struct CryptoBoxTests {
    private static let kek = CryptoBox.generateKeyData(byteCount: 32)

    @Test("round trip preserves arbitrary bytes exactly")
    func roundTrip() throws {
        let payloads: [Data] = [
            Data(),
            Data("hello".utf8),
            Data((0..<4096).map { UInt8($0 % 251) }),
            CryptoBox.generateKeyData(byteCount: 1_048_577), // non-block-aligned
        ]
        for payload in payloads {
            let framed = try CryptoBox.encrypt(payload, keyEncryptionKey: Self.kek)
            #expect(CryptoBox.isEncryptedFile(framed))
            #expect(try CryptoBox.decrypt(framed, keyEncryptionKey: Self.kek) == payload)
        }
    }

    @Test("every file gets an independent content key")
    func uniqueDEKPerFile() throws {
        let plaintext = Data("same plaintext".utf8)
        let first = try CryptoBox.encrypt(plaintext, keyEncryptionKey: Self.kek)
        let second = try CryptoBox.encrypt(plaintext, keyEncryptionKey: Self.kek)
        // Random DEK + random nonces must make ciphertexts differ.
        #expect(first != second)
    }

    @Test("tampering with the payload fails authentication")
    func tamperPayload() throws {
        var framed = try CryptoBox.encrypt(Data("secret".utf8), keyEncryptionKey: Self.kek)
        framed[framed.count - 1] ^= 0xFF
        #expect(throws: CryptoBoxError.authenticationFailure) {
            _ = try CryptoBox.decrypt(framed, keyEncryptionKey: Self.kek)
        }
    }

    @Test("tampering with the wrapped DEK fails authentication")
    func tamperWrappedKey() throws {
        var framed = try CryptoBox.encrypt(Data("secret".utf8), keyEncryptionKey: Self.kek)
        framed[30] ^= 0x01
        #expect(throws: CryptoBoxError.authenticationFailure) {
            _ = try CryptoBox.decrypt(framed, keyEncryptionKey: Self.kek)
        }
    }

    @Test("a wrong KEK fails cleanly with authentication failure")
    func wrongKEK() throws {
        let framed = try CryptoBox.encrypt(Data("secret".utf8), keyEncryptionKey: Self.kek)
        let other = CryptoBox.generateKeyData(byteCount: 32)
        #expect(throws: CryptoBoxError.authenticationFailure) {
            _ = try CryptoBox.decrypt(framed, keyEncryptionKey: other)
        }
    }

    @Test("framing validation rejects short and foreign inputs")
    func framingValidation() throws {
        #expect(!CryptoBox.isEncryptedFile(Data("plaintext json {}".utf8)))
        #expect(throws: CryptoBoxError.framingTooShort(byteCount: 4)) {
            _ = try CryptoBox.decrypt(Data([1, 2, 3, 4]), keyEncryptionKey: Self.kek)
        }
        var foreignMagic = try CryptoBox.encrypt(
            Data("secret".utf8),
            keyEncryptionKey: Self.kek
        )
        foreignMagic[0] = UInt8(ascii: "X")
        #expect(throws: CryptoBoxError.unknownMagic) {
            _ = try CryptoBox.decrypt(foreignMagic, keyEncryptionKey: Self.kek)
        }
    }
}
