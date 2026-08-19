import Foundation
import StenoDomain
import Testing
@testable import StenoPipeline

@Suite("Transcript edit")
struct TranscriptEditTests {
    private func revision(
        _ texts: [String],
        id: RevisionID = RevisionID()
    ) -> TranscriptRevision {
        TranscriptRevision(
            id: id,
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: texts.enumerated().map { index, text in
                TranscriptTurn(
                    speaker: .channel("Other"),
                    start: Double(index) * 10,
                    end: Double(index) * 10 + 8,
                    segments: [TranscriptSegment(
                        text: text,
                        start: Double(index) * 10,
                        end: Double(index) * 10 + 8,
                        words: [TranscriptWord(
                            text: text,
                            start: Double(index) * 10,
                            end: Double(index) * 10 + 8
                        )]
                    )]
                )
            }
        )
    }

    @Test("a correction becomes a new revision that points at the one it fixes")
    func createsChildRevision() throws {
        let original = revision(["Hallo Welt", "Zweiter Turn"])

        let edited = try TranscriptEdit.replacingText(
            in: original,
            turnIndex: 0,
            with: "  Hallo   Welt!  "
        )

        #expect(edited.origin == .userEdit(original.id))
        #expect(edited.meetingID == original.meetingID)
        #expect(edited.id != original.id)
        #expect(edited.turns.count == 2)
        #expect(edited.turns[0].segments.map(\.text) == ["Hallo   Welt!"])
        // Die alte Revision bleibt unangetastet - sie ist der Beleg dafuer,
        // was die Erkennung wirklich geliefert hat.
        #expect(original.turns[0].segments.map(\.text) == ["Hallo Welt"])
    }

    @Test("the turn keeps its speaker and its time, but loses its word timings")
    func keepsTimingDropsWords() throws {
        let original = revision(["Hallo Welt"])

        let edited = try TranscriptEdit.replacingText(
            in: original,
            turnIndex: 0,
            with: "Hallo schoene Welt"
        )

        let turn = try #require(edited.turns.first)
        #expect(turn.speaker == original.turns[0].speaker)
        #expect(turn.start == original.turns[0].start)
        #expect(turn.end == original.turns[0].end)
        #expect(turn.segments.count == 1)
        #expect(turn.segments[0].start == turn.start)
        #expect(turn.segments[0].end == turn.end)
        // Fuer neu getippten Text gibt es keine Wortzeiten. Die alten weiter
        // mitzuschleppen hiesse, Zeiten fuer andere Woerter zu behaupten.
        #expect(turn.segments[0].words.isEmpty)
    }

    @Test("other turns are untouched, including their word timings")
    func leavesOtherTurnsAlone() throws {
        let original = revision(["Eins", "Zwei", "Drei"])

        let edited = try TranscriptEdit.replacingText(
            in: original,
            turnIndex: 1,
            with: "Zwei korrigiert"
        )

        #expect(edited.turns[0] == original.turns[0])
        #expect(edited.turns[2] == original.turns[2])
        #expect(edited.turns[0].segments[0].words.count == 1)
    }

    @Test("empty text is refused instead of quietly deleting the turn")
    func refusesEmptyText() {
        let original = revision(["Hallo"])

        #expect(throws: TranscriptEdit.Failure.emptyText) {
            _ = try TranscriptEdit.replacingText(
                in: original,
                turnIndex: 0,
                with: "   \n "
            )
        }
    }

    @Test("unchanged text creates no revision")
    func refusesNoOpEdit() {
        let original = revision(["Hallo Welt"])

        #expect(throws: TranscriptEdit.Failure.unchanged) {
            _ = try TranscriptEdit.replacingText(
                in: original,
                turnIndex: 0,
                with: " Hallo Welt "
            )
        }
    }

    @Test("an index outside the transcript is refused")
    func refusesBadIndex() {
        #expect(throws: TranscriptEdit.Failure.turnOutOfRange) {
            _ = try TranscriptEdit.replacingText(
                in: revision(["Hallo"]),
                turnIndex: 7,
                with: "Text"
            )
        }
    }

    @Test("a turn split over several segments becomes one after the edit")
    func collapsesSegments() throws {
        let original = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: [TranscriptTurn(
                speaker: nil,
                start: 0,
                end: 10,
                segments: [
                    TranscriptSegment(text: "Erster Teil", start: 0, end: 5, words: []),
                    TranscriptSegment(text: "zweiter Teil", start: 5, end: 10, words: []),
                ]
            )]
        )

        let edited = try TranscriptEdit.replacingText(
            in: original,
            turnIndex: 0,
            with: "Ein Satz"
        )

        #expect(edited.turns[0].segments.count == 1)
        #expect(edited.turns[0].segments[0].text == "Ein Satz")
    }

    @Test("the comparison sees the joined turn text, not the first segment")
    func comparesTheWholeTurn() {
        let original = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: [TranscriptTurn(
                speaker: nil,
                start: 0,
                end: 10,
                segments: [
                    TranscriptSegment(text: "Erster Teil", start: 0, end: 5, words: []),
                    TranscriptSegment(text: "zweiter Teil", start: 5, end: 10, words: []),
                ]
            )]
        )

        // Sonst gilt der unveraenderte Text als Aenderung und legt bei jedem
        // Speichern eine neue Revision an.
        #expect(throws: TranscriptEdit.Failure.unchanged) {
            _ = try TranscriptEdit.replacingText(
                in: original,
                turnIndex: 0,
                with: "Erster Teil zweiter Teil"
            )
        }
    }
}
