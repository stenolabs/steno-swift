import Testing
@testable import StenoExchange

@Suite("Legacy speakers reader")
struct LegacySpeakersFileTests {
    @Test("reads channel-local clusters and their 256-dimensional embeddings")
    func readsClusters() throws {
        let file = try LegacySpeakersFile.read(
            from: Fixture.url("legacy_speakers", extension: "json")
        )

        #expect(file.meetingID == "Umlaut Über")
        #expect(file.createdAt.timeIntervalSince1970 == 1_785_862_866.9)
        #expect(file.channels["mic"]?.recordingType == .inPerson)
        #expect(file.channels["mic"]?.clusters["SPEAKER_0"]?.embedding.count == 256)
        #expect(file.channels["mic"]?.clusters["SPEAKER_0"]?.containsMultipleSpeakers == true)
        #expect(file.channels["system"]?.clusters["SPEAKER_0"]?.reviewState == "generic")
    }

    @Test("pairs transcript_lines strictly by position, never timestamp")
    func pairsTranscriptLinesByPosition() throws {
        let file = try LegacySpeakersFile.read(
            from: Fixture.url("legacy_speakers", extension: "json")
        )
        let turns = [
            LegacyTranscriptTurn(start: 5, speaker: "You", text: "Erste Zeile"),
            LegacyTranscriptTurn(start: 65, speaker: "Speaker 2", text: "Zweite Zeile"),
        ]

        let pairs = try file.pairTranscriptLines(with: turns)

        #expect(pairs[0].turn.text == "Erste Zeile")
        #expect(pairs[0].line.start == 65)
        #expect(pairs[0].line.channel == "mic")
        #expect(pairs[1].turn.text == "Zweite Zeile")
        #expect(pairs[1].line.start == 5)
        #expect(pairs[1].line.channel == "system")
    }

    @Test("accepts old speaker files without transcript_lines")
    func acceptsMissingManifest() throws {
        let file = try LegacySpeakersFile.read(
            from: Fixture.url("legacy_speakers_without_lines", extension: "json")
        )

        #expect(file.transcriptLines == nil)
        #expect(throws: LegacyExchangeError.self) {
            try file.pairTranscriptLines(with: [])
        }
    }

    @Test("rejects a transcript_lines manifest with a different position count")
    func rejectsMismatchedManifest() throws {
        let file = try LegacySpeakersFile.read(
            from: Fixture.url("legacy_speakers", extension: "json")
        )

        #expect(throws: LegacyExchangeError.transcriptLineCountMismatch(expected: 1, actual: 2)) {
            try file.pairTranscriptLines(with: [
                LegacyTranscriptTurn(start: 5, speaker: "You", text: "Nur eine Zeile"),
            ])
        }
    }

    @Test("keeps slash-containing channel and cluster names distinct")
    func slashContainingClusterKeysRemainDistinct() {
        let first = LegacyClusterKey(channel: "a/b", speakerID: "c")
        let second = LegacyClusterKey(channel: "a", speakerID: "b/c")
        let firstSegments = [LegacySpeakerSegment(start: 1, end: 2)]
        let secondSegments = [LegacySpeakerSegment(start: 3, end: 4)]

        let segments = legacySegmentsByClusterID([
            (key: first, segments: firstSegments),
            (key: second, segments: secondSegments),
        ])

        #expect(first != second)
        #expect(first.clusterID != second.clusterID)
        #expect(segments.count == 2)
        #expect(segments[first.clusterID] == firstSegments)
        #expect(segments[second.clusterID] == secondSegments)
    }
}
