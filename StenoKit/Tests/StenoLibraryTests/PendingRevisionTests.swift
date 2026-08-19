import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

/// Eine Benutzerkorrektur darf von einem spaeteren Lauf nicht stillschweigend
/// ueberschrieben werden - deshalb parkt der Lauf als Kandidat. Dieser Test
/// haelt den Weg fest, auf dem der Benutzer ihn wieder herausbekommt: ohne ihn
/// wartet der Kandidat fuer immer, und wer neu transkribiert, sieht nie ein
/// Ergebnis.
@Suite("Pending revision")
struct PendingRevisionTests {
    private func revision(
        meetingID: MeetingID,
        origin: TranscriptOrigin,
        text: String
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: meetingID,
            origin: origin,
            turns: [TranscriptTurn(
                speaker: nil,
                start: 0,
                end: 5,
                segments: [TranscriptSegment(text: text, start: 0, end: 5, words: [])]
            )]
        )
    }

    @Test("a run after a user edit parks, and can be adopted afterwards")
    func adoptsTheParkedRun() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Sync", status: .ready)

            let first = revision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                text: "Erkannt"
            )
            _ = try await library.appendRevision(first)
            let edit = revision(
                meetingID: meeting.id,
                origin: .userEdit(first.id),
                text: "Korrigiert"
            )
            _ = try await library.appendRevision(edit)

            let rerun = revision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                text: "Neu erkannt"
            )
            let parked = try await library.appendRevision(rerun)

            // Der Neulauf uebernimmt nicht von selbst.
            #expect(parked.currentRevisionID == edit.id)
            #expect(parked.pendingCandidate == rerun.id)
            #expect(try await library.pendingRevision(meetingID: meeting.id)?.id == rerun.id)

            let adopted = try #require(
                try await library.adoptPendingRevision(meetingID: meeting.id)
            )

            #expect(adopted.currentRevisionID == rerun.id)
            #expect(adopted.pendingCandidate == nil)
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id).id == rerun.id)
            // Nichts wird verworfen: die Korrektur ist weiter lesbar.
            #expect(try await library.loadRevision(edit.id, meetingID: meeting.id).id == edit.id)
        }
    }

    @Test("without a parked run adopting does nothing")
    func adoptingWithoutCandidateIsANoop() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Sync", status: .ready)
            let first = revision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                text: "Erkannt"
            )
            _ = try await library.appendRevision(first)

            #expect(try await library.adoptPendingRevision(meetingID: meeting.id) == nil)
            #expect(try await library.pendingRevision(meetingID: meeting.id) == nil)
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id).id == first.id)
        }
    }

    @Test("a correction on a stale parent is refused")
    func refusesStaleParent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Sync", status: .ready)
            let first = revision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                text: "Erkannt"
            )
            _ = try await library.appendRevision(first)
            let second = revision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                text: "Neuer Lauf"
            )
            _ = try await library.appendRevision(second)

            // Wer eine Korrektur gegen den ueberholten Stand speichert, hat
            // etwas anderes vor Augen gehabt als das, was gespeichert ist.
            await #expect(throws: LibraryError.self) {
                _ = try await library.appendRevision(revision(
                    meetingID: meeting.id,
                    origin: .userEdit(first.id),
                    text: "Korrigiert"
                ))
            }
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id).id == second.id)
        }
    }
}
