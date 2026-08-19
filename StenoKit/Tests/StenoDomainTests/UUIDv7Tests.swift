import Foundation
import Testing
@testable import StenoDomain

@Suite("UUIDv7")
struct UUIDv7Tests {
    @Test("uses the RFC 9562 version and variant bits")
    func versionAndVariant() {
        let uuid = UUIDv7Generator().generate(
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let bytes = uuidBytes(uuid)

        #expect(Array(bytes.prefix(6)) == [0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x00])
        #expect(bytes[6] >> 4 == 0b0111)
        #expect(bytes[8] >> 6 == 0b10)
    }

    @Test("sorts lexicographically by generation time")
    func temporalSortability() {
        let generator = UUIDv7Generator()
        let earlier = generator.generate(
            at: Date(timeIntervalSince1970: 1_700_000_000.100)
        )
        let later = generator.generate(
            at: Date(timeIntervalSince1970: 1_700_000_000.200)
        )

        #expect(earlier.uuidString < later.uuidString)
    }

    @Test("remains monotonic within one millisecond")
    func sameMillisecondMonotonicity() {
        let generator = UUIDv7Generator()
        let instant = Date(timeIntervalSince1970: 1_700_000_000.123)
        let values = (0..<256).map { _ in generator.generate(at: instant).uuidString }

        #expect(values == values.sorted())
        #expect(Set(values).count == values.count)
    }

    private func uuidBytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }
}
