import Foundation
import StenoDomain
@testable import StenoLibrary
import Testing

@Suite("Recorded track provenance keys")
struct RecordedTrackProvenanceKeyTests {
    private let meetingID = MeetingID()

    @Test("the first track keeps the historical key")
    func firstTrackKeepsLegacyKey() {
        #expect(
            RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: .micTrack,
                sequence: 1
            )
                == "\(meetingID)/micTrack"
        )
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "\(meetingID)/systemTrack",
                meetingID: meetingID,
                kind: .systemTrack
            ) == 1
        )
    }

    @Test("appended tracks carry a sequence suffix")
    func appendedTracksCarrySequence() {
        #expect(
            RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: .micTrack,
                sequence: 2
            )
                == "\(meetingID)/micTrack#2"
        )
        #expect(
            RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: .systemTrack,
                sequence: 7
            )
                == "\(meetingID)/systemTrack#7"
        )
    }

    @Test("sequence parsing round-trips and rejects foreign keys")
    func parsingRejectsForeignKeys() {
        // Round trip for every sequence.
        for sequence in [1, 2, 3, 42] {
            let key = RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: .micTrack,
                sequence: sequence
            )
            #expect(
                RecordedTrackProvenanceKey.sequence(
                    of: key,
                    meetingID: meetingID,
                    kind: .micTrack
                ) == sequence
            )
        }
        // A different kind or meeting never parses.
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "\(meetingID)/micTrack",
                meetingID: meetingID,
                kind: .systemTrack
            ) == nil
        )
        let otherMeeting = MeetingID()
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "\(meetingID)/micTrack",
                meetingID: otherMeeting,
                kind: .micTrack
            ) == nil
        )
        // Imports, legacy stems, and transfers stay foreign.
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "legacy:some-stem",
                meetingID: meetingID,
                kind: .micTrack
            ) == nil
        )
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "sha256:\(String(repeating: "a", count: 64))",
                meetingID: meetingID,
                kind: .imported
            ) == nil
        )
        #expect(
            RecordedTrackProvenanceKey.sequence(
                of: "transfer:\(meetingID):track-1:\(String(repeating: "b", count: 64))",
                meetingID: meetingID,
                kind: .micTrack
            ) == nil
        )
    }

    @Test("next sequence counts up per kind within a meeting")
    func nextSequenceCountsUpPerKind() {
        func asset(
            _ key: String,
            kind: MediaAsset.Kind
        ) -> MediaAsset {
            MediaAsset(
                meetingID: meetingID,
                kind: kind,
                sampleRate: 48_000,
                duration: 1,
                provenanceKey: key,
                fileName: UUID().uuidString
            )
        }
        // Empty library: first track uses the historical slot.
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .micTrack,
                in: []
            ) == 1
        )

        let micFirst = asset("\(meetingID)/micTrack", kind: .micTrack)
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .micTrack,
                in: [micFirst]
            ) == 2
        )
        // Other kinds do not advance the mic counter.
        let systemFirst = asset("\(meetingID)/systemTrack", kind: .systemTrack)
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .micTrack,
                in: [micFirst, systemFirst]
            ) == 2
        )
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .systemTrack,
                in: [micFirst, systemFirst]
            ) == 2
        )
        // Two appends later the counter follows the highest sequence.
        let micSecond = asset("\(meetingID)/micTrack#2", kind: .micTrack)
        let micThird = asset("\(meetingID)/micTrack#3", kind: .micTrack)
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .micTrack,
                in: [micFirst, systemFirst, micSecond, micThird]
            ) == 4
        )
        // Assets of other meetings are irrelevant.
        let foreignMeeting = MeetingID()
        let foreign = MediaAsset(
            meetingID: foreignMeeting,
            kind: .micTrack,
            sampleRate: 48_000,
            duration: 1,
            provenanceKey: "\(foreignMeeting)/micTrack#9",
            fileName: UUID().uuidString
        )
        #expect(
            RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: .micTrack,
                in: [micFirst, foreign]
            ) == 2
        )
    }
}
