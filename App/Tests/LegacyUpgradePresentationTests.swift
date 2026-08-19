import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Legacy upgrade presentation")
struct LegacyUpgradePresentationTests {
    private let meetingID = MeetingID()

    @Test("Legacy import offers the complete repair action")
    func legacyImportOffersRepair() {
        #expect(state() == .ready(actionTitle: "Re-transcribe and detect speakers"))
    }

    @Test("Diarization stays visible after final ASR changed the revision origin")
    func diarizationRemainsVisibleAfterASR() {
        let asrRun = RunID()
        let job = makeJob(kind: .diarization, status: .running)

        #expect(
            state(
                revision: makeRevision(origin: .finalRun(asrRun)),
                jobs: [job],
                needsTranscriptionFirst: false
            ) == .running(job: job)
        )
    }

    @Test("Imported review data does not masquerade as a completed new run")
    func staleImportedReviewDoesNotCompleteUpgrade() {
        let oldRunID = RunID()

        #expect(
            state(
                revision: makeRevision(
                    origin: .legacyImport,
                    speaker: .cluster(runID: oldRunID, clusterID: "legacy-speaker")
                ),
                reviewRunID: oldRunID
            ) == .ready(actionTitle: "Re-transcribe and detect speakers")
        )
    }

    @Test("Current speaker review completes the upgrade")
    func currentReviewCompletesUpgrade() {
        let runID = RunID()

        #expect(
            state(
                revision: makeRevision(origin: .finalRun(runID)),
                reviewRunID: runID,
                needsTranscriptionFirst: false
            ) == .hidden
        )
    }

    @Test("A failed chain remains visible and retryable")
    func failureRemainsRetryable() {
        let job = makeJob(
            kind: .diarization,
            status: .failed,
            errorMessage: "model failed"
        )

        #expect(
            state(
                jobs: [job],
                needsTranscriptionFirst: false
            ) == .failed(
                message: "model failed",
                actionTitle: "Detect speakers"
            )
        )
    }

    @Test("Finished diarization alone does not complete the upgrade")
    func finishedDiarizationDoesNotCompleteUpgrade() {
        let failedAt = Date(timeIntervalSinceReferenceDate: 100)
        let finishedAt = Date(timeIntervalSinceReferenceDate: 200)

        #expect(
            state(
                jobs: [
                    makeJob(
                        kind: .diarization,
                        status: .failed,
                        createdAt: failedAt,
                        errorMessage: "old failure"
                    ),
                    makeJob(
                        kind: .diarization,
                        status: .finished,
                        createdAt: finishedAt
                    ),
                ],
                needsTranscriptionFirst: false
            ) == .ready(actionTitle: "Detect speakers")
        )
    }

    @Test("A failed voice comparison remains visible after diarization")
    func failedIdentitySuggestionRemainsRetryable() {
        let diarization = makeJob(kind: .diarization, status: .finished)
        let comparison = makeJob(
            kind: .identitySuggestion,
            status: .failed,
            createdAt: diarization.createdAt.addingTimeInterval(1),
            errorMessage: "comparison failed"
        )

        #expect(
            state(
                jobs: [diarization, comparison],
                needsTranscriptionFirst: false
            ) == .failed(
                message: "comparison failed",
                actionTitle: "Detect speakers"
            )
        )
    }

    @Test("Legacy meeting without audio has no action")
    func noAudioHasNoAction() {
        #expect(state(hasAudio: false) == .unavailable)
    }

    @Test("Normal meeting has no legacy upgrade presentation")
    func normalMeetingIsHidden() {
        let meeting = Meeting(title: "Normal", status: .ready)

        #expect(LegacyUpgradePresentation.state(
            meeting: meeting,
            revision: makeRevision(origin: .finalRun(RunID())),
            reviewRunID: nil,
            jobs: [],
            hasAudio: true,
            needsTranscriptionFirst: false
        ) == .hidden)
    }

    @Test("Every processing job has an explicit step")
    func stepTitles() {
        #expect(LegacyUpgradePresentation.stepTitle(for: .finalASR)
            == "Transcription, step 1 of 3")
        #expect(LegacyUpgradePresentation.stepTitle(for: .diarization)
            == "Detecting speakers, step 2 of 3")
        #expect(LegacyUpgradePresentation.stepTitle(for: .identitySuggestion)
            == "Comparing voices, step 3 of 3")
    }

    private func state(
        revision: TranscriptRevision? = nil,
        reviewRunID: RunID? = nil,
        jobs: [Job] = [],
        hasAudio: Bool = true,
        needsTranscriptionFirst: Bool = true
    ) -> LegacyUpgradePresentation {
        LegacyUpgradePresentation.state(
            meeting: Meeting(
                id: meetingID,
                title: "Legacy",
                status: .ready,
                metadata: MeetingMetadata(legacyProvenanceKey: "legacy:test")
            ),
            revision: revision ?? makeRevision(origin: .legacyImport),
            reviewRunID: reviewRunID,
            jobs: jobs,
            hasAudio: hasAudio,
            needsTranscriptionFirst: needsTranscriptionFirst
        )
    }

    private func makeRevision(
        origin: TranscriptOrigin,
        speaker: SpeakerReference? = nil
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: meetingID,
            origin: origin,
            turns: [TranscriptTurn(
                speaker: speaker,
                start: 0,
                end: 1,
                segments: []
            )]
        )
    }

    private func makeJob(
        kind: Job.Kind,
        status: Job.Status,
        createdAt: Date = Date(),
        errorMessage: String? = nil
    ) -> Job {
        Job(
            kind: kind,
            meetingID: meetingID,
            status: status,
            createdAt: createdAt,
            errorMessage: errorMessage
        )
    }
}
