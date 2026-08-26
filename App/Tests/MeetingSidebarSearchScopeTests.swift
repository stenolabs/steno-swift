import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import steno_macos

@Suite("Meeting sidebar search routing")
struct MeetingSidebarSearchScopeTests {
    private static func meeting(_ number: Int, title: String) -> Meeting {
        Meeting(
            title: title,
            createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
            status: .ready
        )
    }

    @Test("titles scope filters with the existing title search")
    func titlesScopeUsesTitleFilter() {
        let meetings = [
            Self.meeting(1, title: "Budget Review"),
            Self.meeting(2, title: "Standup"),
        ]
        let results = MeetingSidebarSearchRouter.results(
            query: "budget",
            scope: .titles,
            meetings: meetings,
            contentGroups: []
        )
        #expect(results.count == 1)
        #expect(results.first?.meetingID == meetings[0].id)
        #expect(results.first?.snippet == "Budget Review")
    }

    @Test("allContent scope flattens index groups one hit per meeting")
    func allContentScopeFlattensGroups() throws {
        let groupA = MeetingContentGroup(
            meetingID: MeetingID(),
            hits: [
                MeetingContentHit(source: .transcript, snippet: "...budget talk...")
            ]
        )
        let groupB = MeetingContentGroup(
            meetingID: MeetingID(),
            hits: [
                MeetingContentHit(source: .note, snippet: "...BUDGET note..."),
                MeetingContentHit(source: .report, snippet: "...unrelated..."),
            ]
        )
        let results = MeetingSidebarSearchRouter.results(
            query: "budget",
            scope: .allContent,
            meetings: [],
            contentGroups: [groupA, groupB]
        )
        // Index ordering is preserved; snippet prefers a fold-matching hit.
        #expect(results.map(\.meetingID) == [groupA.meetingID, groupB.meetingID])
        #expect(results[1].snippet == "...BUDGET note...")
    }

    @Test("empty query returns nothing in content scope")
    func emptyQueryReturnsNothingForContent() {
        let results = MeetingSidebarSearchRouter.results(
            query: "   ",
            scope: .allContent,
            meetings: [],
            contentGroups: [
                MeetingContentGroup(
                    meetingID: MeetingID(),
                    hits: [MeetingContentHit(source: .note, snippet: "anything")]
                )
            ]
        )
        #expect(results.isEmpty)
    }
}
