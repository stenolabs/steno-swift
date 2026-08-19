import StenoDomain
import Testing
@testable import Steno

@Suite("View identity generation")
struct ViewIdentityGenerationTests {
    @Test("a delayed response is rejected after the meeting changes")
    func rejectsPreviousMeetingResponse() {
        let meetingA = MeetingID()
        let meetingB = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        let requestA = identity.begin(meetingA)

        let requestB = identity.begin(meetingB)

        #expect(!identity.accepts(requestA, currentValue: meetingB))
        #expect(identity.accepts(requestB, currentValue: meetingB))
        #expect(identity.token(for: meetingA) == nil)
        #expect(identity.token(for: meetingB) == requestB)
    }

    @Test("a newer generation rejects an older response for the same meeting")
    func rejectsPreviousGeneration() {
        let meeting = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        let first = identity.begin(meeting)

        let second = identity.begin(meeting)

        #expect(!identity.accepts(first, currentValue: meeting))
        #expect(identity.accepts(second, currentValue: meeting))
    }
}
