import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Template render pin-failure observation")
struct TemplateRenderPinsFailureObservationLedgerTests {
    @Test("only the newest relevant pin failure can be claimed once")
    func claimsNewestRelevantFailureOnce() throws {
        let ledger = TemplateRenderPinsFailureObservationLedger()
        let meetingID = MeetingID()
        let older = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            failureReason: .templateRenderPinsRequired
        )
        let latest = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 2),
            failureReason: .templateRenderPinsRequired
        )

        let first = try #require(ledger.claimLatestFailure(in: [latest, older]))

        #expect(first.id == latest.id)
        #expect(ledger.claimLatestFailure(in: [older, latest]) == nil)
    }

    @Test("a newer template job supersedes an old pin failure")
    func newerJobSuppressesOldFailure() {
        let ledger = TemplateRenderPinsFailureObservationLedger()
        let meetingID = MeetingID()
        let failed = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            failureReason: .templateRenderPinsRequired
        )
        let newer = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .finished,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        #expect(ledger.claimLatestFailure(in: [failed, newer]) == nil)
    }

    @Test("non-template jobs do not supersede a template failure")
    func ignoresOtherJobKinds() throws {
        let ledger = TemplateRenderPinsFailureObservationLedger()
        let meetingID = MeetingID()
        let failed = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            failureReason: .templateRenderPinsRequired
        )
        let unrelated = Job(
            kind: .finalASR,
            meetingID: meetingID,
            status: .finished,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let claimed = try #require(
            ledger.claimLatestFailure(in: [failed, unrelated])
        )
        #expect(claimed.id == failed.id)
    }
}
