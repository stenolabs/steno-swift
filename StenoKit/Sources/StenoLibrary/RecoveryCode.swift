import CryptoKit
import Foundation

/// Human-readable base32 recovery code for the library encryption beta.
///
/// A generated code carries 160 bits of entropy encoded as 32 RFC-4648
/// base32 characters, displayed in dash-separated groups of four:
/// `ABCD-EFGH-...`. The code unlocks the KEK backup blob stored inside the
/// library header (`LibraryEncryptionHeader`), so the code alone - without
/// any Keychain entry - can recover the key.
///
/// Normalization is deliberately forgiving: input may mix case, contain
/// dashes, spaces, or underscores, and the visually ambiguous digits
/// `0` and `1` map onto the letters `O` and `I`. Generated codes never
/// contain those digits, so the mapping is unambiguous.
public struct RecoveryCode: Hashable, Sendable {
    public enum CodeError: Error, Equatable, Sendable {
        case invalidCharacters(position: Int)
        case invalidLength(characterCount: Int)
    }

    /// Uppercase base32 characters only, no separators.
    public let normalized: String

    /// Parses and normalizes user input; throws typed errors for clean UI
    /// feedback on malformed codes.
    public init(_ rawInput: String) throws {
        var cleaned: [Character] = []
        cleaned.reserveCapacity(Self.characterCount)
        var position = 0
        for rawCharacter in rawInput.uppercased() {
            if ["-", "_", " "].contains(rawCharacter) { continue }
            let mapped = Self.normalize(rawCharacter)
            guard Self.base32Alphabet.contains(mapped) else {
                throw RecoveryCode.CodeError.invalidCharacters(position: position)
            }
            cleaned.append(mapped)
            position += 1
        }
        guard cleaned.count == Self.characterCount else {
            throw RecoveryCode.CodeError.invalidLength(
                characterCount: cleaned.count
            )
        }
        normalized = String(cleaned)
    }

    /// Generates a fresh code from 160 bits of secure randomness.
    public static func generate() -> RecoveryCode {
        let bytes = CryptoBox.generateKeyData(byteCount: 20)
        return RecoveryCode(normalized: base32Encode(bytes))
    }

    /// Dash-separated display form, groups of four.
    public var displayText: String {
        var groups: [String] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let end = normalized.index(index, offsetBy: 4, limitedBy: normalized.endIndex) ?? normalized.endIndex
            groups.append(String(normalized[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    /// Raw decoded entropy feeding the HKDF recovery-key derivation.
    public var keyMaterial: Data {
        base32Decode(normalized)
    }

    private init(normalized: String) {
        self.normalized = normalized
    }

    static let characterCount = 32
    static let base32Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func normalize(_ character: Character) -> Character {
        switch character {
        case "0": return "O"
        case "1": return "I"
        default: return character
        }
    }
}

// MARK: - RFC 4648 base32 (no padding)

private func base32Encode(_ data: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var output: [Character] = []
    output.reserveCapacity(32)
    var buffer = 0
    var bufferBits = 0
    for byte in data {
        buffer = (buffer << 8) | Int(byte)
        bufferBits += 8
        while bufferBits >= 5 {
            bufferBits -= 5
            output.append(alphabet[(buffer >> bufferBits) & 0x1F])
        }
    }
    if bufferBits > 0 {
        output.append(alphabet[(buffer << (5 - bufferBits)) & 0x1F])
    }
    return String(output)
}

private func base32Decode(_ text: String) -> Data {
    var bytes: [UInt8] = []
    var buffer = 0
    var bufferBits = 0
    for character in text.utf8 {
        let value = base32Value(of: character)
        buffer = (buffer << 5) | value
        bufferBits += 5
        if bufferBits >= 8 {
            bufferBits -= 8
            bytes.append(UInt8((buffer >> bufferBits) & 0xFF))
        }
    }
    return Data(bytes)
}

private func base32Value(of ascii: UInt8) -> Int {
    switch ascii {
    case 65...90: return Int(ascii - 65) // A-Z
    case 50...55: return Int(ascii - 50 + 26) // 2-7
    default: return 0
    }
}
