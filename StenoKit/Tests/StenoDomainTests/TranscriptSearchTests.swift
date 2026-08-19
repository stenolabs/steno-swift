import Foundation
import Testing
@testable import StenoDomain

@Suite("Transcript search")
struct TranscriptSearchTests {
    private func revision(_ texts: [String]) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: texts.map { text in
                TranscriptTurn(
                    speaker: nil,
                    start: 0,
                    end: 1,
                    segments: [TranscriptSegment(text: text, start: 0, end: 1, words: [])]
                )
            }
        )
    }

    @Test("an empty query keeps every turn, in order")
    func emptyQueryMatchesEverything() {
        let all = revision(["Eins", "Zwei", "Drei"])

        #expect(TranscriptSearch.matchingTurnIndices(in: all, query: "") == [0, 1, 2])
        #expect(TranscriptSearch.matchingTurnIndices(in: all, query: "  ") == [0, 1, 2])
    }

    @Test("indices point into the whole transcript, not into the result list")
    func indicesAreAbsolute() {
        let all = revision(["Budget", "Anderes", "Budget erneut", "Nichts"])

        // Das ist die eigentliche Zusage dieser Funktion: wer Treffer 2
        // korrigiert, korrigiert Turn 2 - nicht den zweiten Turn ueberhaupt.
        #expect(TranscriptSearch.matchingTurnIndices(in: all, query: "budget") == [0, 2])
    }

    @Test("case and diacritics do not matter")
    func ignoresCaseAndDiacritics() {
        let all = revision(["Gespräch mit Müller", "Standup"])

        #expect(TranscriptSearch.matchingTurnIndices(in: all, query: "muller") == [0])
        #expect(TranscriptSearch.matchingTurnIndices(in: all, query: "GESPRACH") == [0])
    }

    @Test("a turn made of several segments is searched as one text")
    func searchesAcrossSegments() {
        let split = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: [TranscriptTurn(
                speaker: nil,
                start: 0,
                end: 2,
                segments: [
                    TranscriptSegment(text: "wir brauchen das", start: 0, end: 1, words: []),
                    TranscriptSegment(text: "Budget bis Freitag", start: 1, end: 2, words: []),
                ]
            )]
        )

        #expect(TranscriptSearch.matchingTurnIndices(in: split, query: "das Budget") == [0])
    }

    @Test("no match returns nothing, not everything")
    func noMatchIsEmpty() {
        #expect(TranscriptSearch.matchingTurnIndices(
            in: revision(["Hallo"]),
            query: "zzz"
        ).isEmpty)
    }
}
