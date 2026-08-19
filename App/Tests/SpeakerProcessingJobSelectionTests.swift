import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Speaker processing job selection")
struct SpeakerProcessingJobSelectionTests {
    private let meetingID = MeetingID()

    @Test("Retries the failed voice comparison without repeating diarization")
    func retriesIdentitySuggestion() {
        let sourceRunID = RunID()
        let failed = Job(
            kind: .identitySuggestion,
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            status: .failed,
            errorMessage: "comparison failed"
        )

        let retry = SpeakerProcessingJobSelection.retryJob(in: [failed])

        #expect(retry?.kind == .identitySuggestion)
        #expect(retry?.meetingID == meetingID)
        #expect(retry?.sourceRunID == sourceRunID)
        #expect(retry?.status == .queued)
        #expect(retry?.id != failed.id)
    }

    @Test("A cancelled last step can be continued")
    func retriesCancelledIdentitySuggestion() {
        let sourceRunID = RunID()
        let cancelled = Job(
            kind: .identitySuggestion,
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            status: .cancelled
        )

        #expect(
            SpeakerProcessingJobSelection.retryJob(in: [cancelled])?.kind
                == .identitySuggestion
        )
    }

    @Test("An imported retry preserves its generation and pinned locale")
    func importedRetryPreservesGenerationAndLocale() throws {
        let generationID = MeetingTransferGenerationID()
        let failed = Job(
            kind: .finalASR,
            meetingID: meetingID,
            localeIdentifier: "fr-FR",
            importGenerationID: generationID,
            status: .failed,
            errorMessage: "transcription failed"
        )

        let retry = try #require(SpeakerProcessingJobSelection.retryJob(in: [failed]))

        #expect(retry.importGenerationID == generationID)
        #expect(retry.localeIdentifier == "fr-FR")
        #expect(retry.id != failed.id)
    }

    @Test("A later successful step supersedes its old failure")
    func successfulStepSupersedesFailure() {
        let sourceRunID = RunID()
        let failed = Job(
            kind: .identitySuggestion,
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            status: .failed,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let finished = Job(
            kind: .identitySuggestion,
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            status: .finished,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        #expect(SpeakerProcessingJobSelection.retryJob(in: [failed, finished]) == nil)
    }

    @Test("an active processing job is detected before planning another one")
    func detectsActiveJob() {
        let running = Job(
            kind: .diarization,
            meetingID: meetingID,
            sourceRunID: RunID(),
            status: .running
        )

        #expect(SpeakerProcessingJobSelection.hasActiveJob(in: [running]))
    }
}
