import Foundation
import Testing
@testable import StenoLibrary

@Suite("RecoveryCode")
struct RecoveryCodeTests {
    @Test("generated codes decode back to 160 bits of entropy")
    func generateRoundTrip() throws {
        let code = RecoveryCode.generate()
        #expect(code.normalized.count == RecoveryCode.characterCount)
        #expect(code.keyMaterial.count == 20)
        // Display form: dash-separated groups of four.
        let groups = code.displayText.split(separator: "-")
        #expect(groups.count == 8)
        #expect(groups.dropLast().allSatisfy { $0.count == 4 })
        // Re-parsing the display text must yield the identical code.
        let reparsed = try RecoveryCode(code.displayText)
        #expect(reparsed == code)
    }

    @Test("normalization accepts case, separators, and ambiguous digits")
    func normalization() throws {
        let code = try RecoveryCode("abcd-efgh ijkl_mnop qrst uvwx yz23 4567")
        #expect(code.normalized == "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

        // Generated codes never contain 0 or 1, so mapping them onto O/I
        // is unambiguous.
        let withDigits = try RecoveryCode("AB0D-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567")
        #expect(withDigits.normalized == "ABODEFGHIJKLMNOPQRSTUVWXYZ234567")
    }

    @Test("malformed codes fail with typed errors")
    func malformedInput() {
        #expect(throws: RecoveryCode.CodeError.invalidLength(characterCount: 3)) {
            _ = try RecoveryCode("ABC")
        }
        // '8' is not in the base32 alphabet.
        #expect(throws: RecoveryCode.CodeError.invalidCharacters(position: 2)) {
            _ = try RecoveryCode("AB8D-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567")
        }
    }

    @Test("generation is not deterministic")
    func uniqueness() {
        let first = RecoveryCode.generate()
        let second = RecoveryCode.generate()
        #expect(first != second)
    }
}
