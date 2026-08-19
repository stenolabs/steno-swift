import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Transcript output mapping")
struct TranscriptMapperTests {
    @Test("maps each result block to a time-ordered turn with its channel speaker")
    func mapsBlocksAcrossTracks() {
        let meetingID = MeetingID()
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let microphone = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Hallo Welt",
                    start: 0,
                    end: 1,
                    words: [
                        TranscriptionWord(text: "Hallo", start: 0, end: 0.4),
                        TranscriptionWord(text: "Welt", start: 0.55, end: 1),
                    ]
                ),
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Bis gleich",
                    start: 3,
                    end: 4,
                    words: [
                        TranscriptionWord(text: "Bis", start: 3, end: 3.3),
                        TranscriptionWord(text: "gleich", start: 3.45, end: 4),
                    ]
                ),
            ]
        )
        let system = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .system,
                    text: "Guten Morgen",
                    start: 1.25,
                    end: 2.5,
                    words: [
                        TranscriptionWord(text: "Guten", start: 1.25, end: 1.7),
                        TranscriptionWord(text: "Morgen", start: 1.9, end: 2.5),
                    ]
                ),
            ]
        )

        let revision = TranscriptMapper.revision(
            from: [microphone, system],
            meetingID: meetingID,
            origin: .liveProvisional,
            createdAt: createdAt
        )

        #expect(revision.meetingID == meetingID)
        #expect(revision.createdAt == createdAt)
        #expect(revision.origin == .liveProvisional)
        #expect(revision.turns.count == 3)
        #expect(revision.turns.map(\.start) == [0, 1.25, 3])
        #expect(revision.turns.map(\.speaker) == [
            .channel("Ich"),
            .channel("Andere"),
            .channel("Ich"),
        ])
        #expect(revision.turns[0].segments == [
            TranscriptSegment(
                text: "Hallo Welt",
                start: 0,
                end: 1,
                words: [
                    TranscriptWord(text: "Hallo", start: 0, end: 0.4),
                    TranscriptWord(text: "Welt", start: 0.55, end: 1),
                ]
            ),
        ])
    }

    @Test("groups adjacent result blocks from one track into a turn")
    func groupsAdjacentResultBlocks() {
        let output = TranscriptOutput(
            localeIdentifier: "en-US",
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "First",
                    start: 0,
                    end: 1,
                    words: [TranscriptionWord(text: "First", start: 0, end: 1)]
                ),
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Second",
                    start: 1,
                    end: 2,
                    words: [TranscriptionWord(text: "Second", start: 1, end: 2)]
                ),
            ]
        )

        let revision = TranscriptMapper.revision(
            from: output,
            meetingID: MeetingID(),
            origin: .liveProvisional
        )

        #expect(revision.turns.count == 1)
        #expect(revision.turns[0].start == 0)
        #expect(revision.turns[0].end == 2)
        #expect(revision.turns[0].segments.map(\.text) == ["First", "Second"])
    }

    @Test("clamps word ranges to their result block")
    func clampsWordRanges() {
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .system,
                    text: "Vorher Nachher Umgekehrt",
                    start: 10,
                    end: 12,
                    words: [
                        TranscriptionWord(text: "Vorher", start: 9, end: 10.5),
                        TranscriptionWord(text: "Nachher", start: 11.5, end: 13),
                        TranscriptionWord(text: "Umgekehrt", start: 11.8, end: 11.2),
                    ]
                ),
            ]
        )

        let revision = TranscriptMapper.revision(
            from: output,
            meetingID: MeetingID(),
            origin: .liveProvisional
        )
        let words = revision.turns[0].segments[0].words

        #expect(words == [
            TranscriptWord(text: "Vorher", start: 10, end: 10.5),
            TranscriptWord(text: "Nachher", start: 11.5, end: 12),
            TranscriptWord(text: "Umgekehrt", start: 11.8, end: 11.8),
        ])
    }

    @Test("groups blocks connected through an enclosing result range")
    func groupsTransitivelyOverlappingBlocks() {
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Outer",
                    start: 0,
                    end: 10,
                    words: []
                ),
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Inner",
                    start: 1,
                    end: 2,
                    words: []
                ),
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Connected",
                    start: 9,
                    end: 11,
                    words: []
                ),
            ]
        )

        let revision = TranscriptMapper.revision(
            from: output,
            meetingID: MeetingID(),
            origin: .liveProvisional
        )

        #expect(revision.turns.count == 1)
        #expect(revision.turns[0].end == 11)
        #expect(revision.turns[0].segments.count == 3)
    }

    /// Das Kanallabel ist ein Datenwert und bleibt deutsch; angezeigt wird
    /// es nur ueber `ChannelLabel.speakerLabel`. Der Test haelt beide Seiten
    /// zusammen: kaeme ein Kanal dazu, dessen Label der Aufloeser nicht
    /// kennt, stuende der Rohwert auf dem Bildschirm.
    @Test("every channel speaker label has a display form")
    func channelLabelsAreResolvableForDisplay() {
        for channel in TranscriptionChannel.allCases {
            let raw = channel.speakerLabel
            #expect(ChannelLabel.speakerLabel(raw) != raw)
        }
        #expect(ChannelLabel.speakerLabel(TranscriptionChannel.microphone.speakerLabel) == "Me")
        #expect(ChannelLabel.speakerLabel(TranscriptionChannel.system.speakerLabel) == "Others")
    }
}
