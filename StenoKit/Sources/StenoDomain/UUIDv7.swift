import Foundation
import Synchronization

/// Generates RFC 9562 UUID version 7 values.
///
/// Values from one generator remain strictly ordered even when the wall clock
/// does not advance or moves backwards.
public final class UUIDv7Generator: Sendable {
    public static let shared = UUIDv7Generator()

    private struct State: Sendable {
        var timestampMilliseconds: UInt64?
        var randomA: UInt16 = 0
        var randomB: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func generate(at date: Date = Date()) -> UUID {
        let requestedTimestamp = Self.timestampMilliseconds(for: date)

        return state.withLock { state in
            if let previousTimestamp = state.timestampMilliseconds,
               requestedTimestamp <= previousTimestamp {
                if state.randomB < 0x3fff_ffff_ffff_ffff {
                    state.randomB += 1
                } else if state.randomA < 0x0fff {
                    state.randomA += 1
                    state.randomB = 0
                } else {
                    state.timestampMilliseconds = min(
                        previousTimestamp + 1,
                        0xffff_ffff_ffff
                    )
                    state.randomA = 0
                    state.randomB = 0
                }
            } else {
                state.timestampMilliseconds = requestedTimestamp
                state.randomA = UInt16.random(in: 0...0x0fff)
                state.randomB = UInt64.random(in: 0...0x3fff_ffff_ffff_ffff)
            }

            return Self.makeUUID(
                timestampMilliseconds: state.timestampMilliseconds ?? requestedTimestamp,
                randomA: state.randomA,
                randomB: state.randomB
            )
        }
    }

    private static func timestampMilliseconds(for date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite else { return 0 }
        return UInt64(min(max(milliseconds.rounded(.down), 0), 281_474_976_710_655))
    }

    private static func makeUUID(
        timestampMilliseconds: UInt64,
        randomA: UInt16,
        randomB: UInt64
    ) -> UUID {
        let bytes: uuid_t = (
            UInt8(truncatingIfNeeded: timestampMilliseconds >> 40),
            UInt8(truncatingIfNeeded: timestampMilliseconds >> 32),
            UInt8(truncatingIfNeeded: timestampMilliseconds >> 24),
            UInt8(truncatingIfNeeded: timestampMilliseconds >> 16),
            UInt8(truncatingIfNeeded: timestampMilliseconds >> 8),
            UInt8(truncatingIfNeeded: timestampMilliseconds),
            0x70 | UInt8(truncatingIfNeeded: randomA >> 8),
            UInt8(truncatingIfNeeded: randomA),
            0x80 | UInt8(truncatingIfNeeded: randomB >> 56),
            UInt8(truncatingIfNeeded: randomB >> 48),
            UInt8(truncatingIfNeeded: randomB >> 40),
            UInt8(truncatingIfNeeded: randomB >> 32),
            UInt8(truncatingIfNeeded: randomB >> 24),
            UInt8(truncatingIfNeeded: randomB >> 16),
            UInt8(truncatingIfNeeded: randomB >> 8),
            UInt8(truncatingIfNeeded: randomB)
        )
        return UUID(uuid: bytes)
    }
}
