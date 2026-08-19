import Foundation
import Testing
@testable import StenoExchange

@Suite("Legacy timestamps")
struct LegacyTimestampTests {
    private let parser = LegacyTimestampParser(
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    @Test("all legacy epochs preserve their documented meaning")
    func parsesAllEpochs() throws {
        #expect(parser.date(fromUnixSeconds: 1_785_862_866.9) == Date(timeIntervalSince1970: 1_785_862_866.9))
        #expect(parser.date(fromUnixMilliseconds: 1_785_933_296_000) == Date(timeIntervalSince1970: 1_785_933_296))
        #expect(parser.recordingStartedAt(stem: "sysaudio-1785933296000-Plan") == Date(timeIntervalSince1970: 1_785_933_296))
        #expect(try #require(parser.date(fromISO8601: "2026-08-05T12:34:56Z")) == Date(timeIntervalSince1970: 1_785_933_296))
        #expect(try #require(parser.date(fromISO8601: "2026-08-05T12:34:56")) == Date(timeIntervalSince1970: 1_785_926_096))
        #expect(try #require(parser.date(fromLegacyHeader: "2026-08-05 12:34:56")) == Date(timeIntervalSince1970: 1_785_926_096))
    }
}
