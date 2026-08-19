import StenoDomain
@testable import StenoLibrary
@testable import StenoPipeline
import Testing

@Suite("Meeting processing job requests")
struct MeetingProcessingJobRequestTests {
    @Test("generic processing is rejected for a generation-bound import")
    func generationBoundImportRequiresImportedRetry() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)

            await #expect(
                throws: MeetingProcessingRequestError.importedRetryRequired(
                    fixture.meeting.id
                )
            ) {
                try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
                    library: fixture.library,
                    meetingID: fixture.meeting.id
                )
            }

            #expect(try await fixture.jobStore.list().map(\.id) == [fixture.job.id])
        }
    }

    @Test("generic processing is rejected while imported commit recovery is pending")
    func pendingImportCommitRequiresRecovery() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let receipt = try #require(fixture.meeting.metadata?.transferReceipt)
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: fixture.meeting.id,
                receipt: receipt,
                to: fixture.library.layout.transferCommitPending(fixture.meeting.id)
            )

            await #expect(
                throws: MeetingProcessingRequestError.commitRecoveryRequired(
                    fixture.meeting.id
                )
            ) {
                try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
                    library: fixture.library,
                    meetingID: fixture.meeting.id
                )
            }

            #expect(try await fixture.jobStore.list().map(\.id) == [fixture.job.id])
        }
    }

    @Test("generic processing remains available for a native meeting")
    func nativeMeetingAllowsUnpinnedJob() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)

            try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )
        }
    }
}
