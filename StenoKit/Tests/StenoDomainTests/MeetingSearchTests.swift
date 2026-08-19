import Foundation
import Testing
@testable import StenoDomain

@Suite("Meeting search")
struct MeetingSearchTests {
    private func meeting(_ title: String) -> Meeting {
        Meeting(title: title, status: .ready)
    }

    @Test("an empty query changes nothing")
    func emptyQueryKeepsEverything() {
        let all = [meeting("Sync"), meeting("Review")]

        #expect(MeetingSearch.matching(all, query: "").map(\.title) == ["Sync", "Review"])
        #expect(MeetingSearch.matching(all, query: "   ").count == 2)
    }

    @Test("case and diacritics do not matter")
    func ignoresCaseAndDiacritics() {
        let all = [
            meeting("Gespräch mit Müller"),
            meeting("Standup"),
            meeting("MULLER follow-up"),
        ]

        // Wer "muller" tippt, meint auch "Müller" - sonst sucht er zweimal und
        // glaubt beim zweiten Mal, es gebe die Aufnahme nicht.
        #expect(MeetingSearch.matching(all, query: "muller").count == 2)
        #expect(MeetingSearch.matching(all, query: "MÜLL").count == 2)
        #expect(MeetingSearch.matching(all, query: "stand").map(\.title) == ["Standup"])
    }

    @Test("a query that matches nothing returns nothing, not everything")
    func noMatchIsEmpty() {
        #expect(MeetingSearch.matching([meeting("Sync")], query: "zzz").isEmpty)
    }

    @Test("the order of the input survives")
    func keepsOrder() {
        let all = [meeting("A sync"), meeting("B sync"), meeting("C sync")]

        #expect(MeetingSearch.matching(all, query: "sync").map(\.title) == [
            "A sync", "B sync", "C sync",
        ])
    }
}
