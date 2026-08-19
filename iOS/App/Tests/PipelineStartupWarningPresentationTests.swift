import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import Steno

@Suite("Pipeline startup warning presentation")
struct PipelineStartupWarningPresentationTests {
    @Test("warning stays generic and does not expose a meeting identifier")
    func warningDoesNotExposeMeetingDetails() throws {
        let meetingID = MeetingID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let warning = PipelineStartupWarning.importedMeetingProcessing(
            meetingID: meetingID,
            issue: .invalidTransferState
        )

        let message = try #require(AppModel.pipelineStartupWarningMessage(for: [warning]))

        #expect(message == "One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available.")
        #expect(!message.contains(meetingID.description))
        #expect(AppModel.pipelineStartupWarningMessage(for: []) == nil)
    }
}
