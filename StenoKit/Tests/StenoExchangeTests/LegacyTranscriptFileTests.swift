import Testing
@testable import StenoExchange

@Suite("Legacy transcript reader")
struct LegacyTranscriptFileTests {
    @Test("reads the fixed header and diarized H:MM:SS turns")
    func readsDiarizedTranscript() throws {
        let file = try LegacyTranscriptFile.read(
            from: Fixture.url("diarized_transcript", extension: "txt"),
            timestampParser: LegacyTimestampParser(timeZone: .gmt)
        )

        #expect(file.header.sessionName == "Planung ÄÖÜ")
        #expect(file.header.fileName == "sysaudio-1785933296000-Planung.webm")
        #expect(file.header.detectedLanguage == "German")
        let turns = try #require(file.body.diarizedTurns)
        #expect(turns.count == 2)
        #expect(turns[0] == LegacyTranscriptTurn(start: 5, speaker: "You", text: "Guten Morgen."))
        #expect(turns[1] == LegacyTranscriptTurn(start: 3_665, speaker: "Speaker 2", text: "Hallo zusammen."))
    }

    @Test("keeps non-diarized paragraphs separate and un-timed")
    func readsPlainTranscript() throws {
        let file = try LegacyTranscriptFile.read(
            from: Fixture.url("plain_transcript", extension: "txt"),
            timestampParser: LegacyTimestampParser(timeZone: .gmt)
        )

        #expect(file.body.plainParagraphs == [
            "Erster Absatz mit zwei\nZeilen.",
            "Zweiter Absatz.",
        ])
        #expect(file.body.diarizedTurns == nil)
    }
}
