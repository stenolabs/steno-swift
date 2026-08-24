import Foundation
import Testing
@testable import StenoDomain

@Suite("Pinned transcription plan coding")
struct TranscriptionPlanCodableTests {
    @Test("A meeting retains its pinned provider plan")
    func roundTrip() throws {
        let plan = TranscriptionPlan(
            liveProviderID: .apple,
            finalProviderID: .parakeetTDTv3
        )
        let meeting = Meeting(
            title: "Planungsrunde",
            status: .recording,
            transcriptionPlan: plan
        )

        let decodedMeeting = try JSONDecoder().decode(
            Meeting.self,
            from: JSONEncoder().encode(meeting)
        )

        #expect(decodedMeeting.transcriptionPlan == plan)
    }

    @Test("A schema-one document without a transcription plan remains legacy nil")
    func legacyDocumentsRemainUnpinned() throws {
        let meetingData = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "title": "Legacy",
              "createdAt": 0,
              "status": "ready"
            }
            """.utf8
        )

        let meeting = try JSONDecoder().decode(Meeting.self, from: meetingData)

        #expect(meeting.transcriptionPlan == nil)
    }
}
