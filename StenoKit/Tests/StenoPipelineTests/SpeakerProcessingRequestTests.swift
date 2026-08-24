import Foundation
import StenoDomain
import StenoLibrary
@testable import StenoPipeline
import Testing

@Suite("Speaker processing requests")
struct SpeakerProcessingRequestTests {
    @Test("meeting diarization waits for models without burning a job")
    func meetingDiarizationNeedsModelsBeforeEnqueue() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)

            #expect(
                try await MeetingDiarizationRequest.status(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: false
                ) == .modelsRequired
            )
            #expect(
                try await MeetingDiarizationRequest.request(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: false
                ) == .modelsRequired
            )
            #expect(try await fixture.jobStore.list().isEmpty)
        }
    }

    @Test("meeting diarization creates exactly one job for the current generation")
    func meetingDiarizationEnqueuesOnce() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)

            let first = try await MeetingDiarizationRequest.request(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meetingID,
                modelsReady: true
            )
            let second = try await MeetingDiarizationRequest.request(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meetingID,
                modelsReady: true
            )
            let jobs = try await fixture.jobStore.list()

            #expect(first == .queued)
            #expect(second == .queued)
            #expect(jobs.count == 1)
            #expect(jobs.first?.kind == .diarization)
            #expect(jobs.first?.sourceRunID == fixture.finalASRRunID)
        }
    }

    @Test("two windows still create one diarization job")
    func concurrentMeetingDiarizationEnqueuesOnce() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)

            async let first = MeetingDiarizationRequest.request(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meetingID,
                modelsReady: true
            )
            async let second = MeetingDiarizationRequest.request(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meetingID,
                modelsReady: true
            )

            #expect(try await [first, second] == [.queued, .queued])
            #expect(try await fixture.jobStore.list().count == 1)
        }
    }

    @Test("a text edit keeps the current final-ASR generation")
    func meetingDiarizationFollowsUserEditParent() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)
            _ = try await fixture.library.appendRevision(TranscriptRevision(
                meetingID: fixture.meetingID,
                origin: .userEdit(fixture.revisionID),
                turns: [TranscriptTurn(
                    start: 0,
                    end: 1,
                    segments: [TranscriptSegment(
                        text: "Edited",
                        start: 0,
                        end: 1,
                        words: [TranscriptWord(text: "Edited", start: 0, end: 1)]
                    )]
                )]
            ))

            #expect(
                try await MeetingDiarizationRequest.request(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .queued
            )
            #expect(
                try await fixture.jobStore.list().first?.sourceRunID
                    == fixture.finalASRRunID
            )
        }
    }

    @Test("an imported transcript generation stays pinned")
    func importedMeetingDiarizationKeepsGeneration() async throws {
        try await withTemporaryDirectory { root in
            let generationID = MeetingTransferGenerationID()
            let fixture = try await makeCurrentFinalASRFixture(
                at: root,
                importGenerationID: generationID
            )

            #expect(
                try await MeetingDiarizationRequest.request(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .queued
            )
            #expect(
                try await fixture.jobStore.list().first?.importGenerationID
                    == generationID
            )
        }
    }

    @Test("only a missing-model failure for the current generation is requeued")
    func meetingDiarizationRetriesOnlyMissingModels() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)
            let retryable = Job(
                kind: .diarization,
                meetingID: fixture.meetingID,
                sourceRunID: fixture.finalASRRunID,
                status: .failed,
                failureReason: .diarizationModelsNotInstalled
            )
            let otherFailure = Job(
                kind: .diarization,
                meetingID: fixture.meetingID,
                sourceRunID: RunID(),
                status: .failed,
                errorMessage: "inference failed"
            )
            try await fixture.jobStore.enqueue(retryable)
            try await fixture.jobStore.enqueue(otherFailure)

            #expect(
                try await MeetingDiarizationRequest.request(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .queued
            )
            #expect(try await fixture.jobStore.load(retryable.id).status == .queued)
            #expect(try await fixture.jobStore.load(otherFailure.id).status == .failed)
        }
    }

    @Test("an unpublished result and unrelated failures do not create new work")
    func meetingDiarizationDoesNotOverwriteTerminalJobs() async throws {
        try await withTemporaryDirectory { root in
            let completedFixture = try await makeCurrentFinalASRFixture(
                at: root.appending(path: "completed", directoryHint: .isDirectory)
            )
            let completed = Job(
                kind: .diarization,
                meetingID: completedFixture.meetingID,
                sourceRunID: completedFixture.finalASRRunID,
                status: .finished
            )
            try await completedFixture.jobStore.enqueue(completed)
            #expect(
                try await MeetingDiarizationRequest.request(
                    library: completedFixture.library,
                    jobStore: completedFixture.jobStore,
                    meetingID: completedFixture.meetingID,
                    modelsReady: true
                ) == .running
            )
            #expect(try await completedFixture.jobStore.list().map(\.id) == [completed.id])

            let failedFixture = try await makeCurrentFinalASRFixture(
                at: root.appending(path: "failed", directoryHint: .isDirectory)
            )
            let failed = Job(
                kind: .diarization,
                meetingID: failedFixture.meetingID,
                sourceRunID: failedFixture.finalASRRunID,
                status: .failed,
                errorMessage: "inference failed"
            )
            try await failedFixture.jobStore.enqueue(failed)
            #expect(
                try await MeetingDiarizationRequest.request(
                    library: failedFixture.library,
                    jobStore: failedFixture.jobStore,
                    meetingID: failedFixture.meetingID,
                    modelsReady: true
                ) == .failed("inference failed")
            )
            #expect(try await failedFixture.jobStore.load(failed.id).status == .failed)
        }
    }

    @Test("a diarized current revision resolves back to its final-ASR source")
    func completedDiarizationFollowsArtifactSource() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)
            let completed = Job(
                kind: .diarization,
                meetingID: fixture.meetingID,
                sourceRunID: fixture.finalASRRunID,
                status: .finished
            )
            let diarizationRunID = StablePipelineIdentifiers.runID(for: completed)
            let revisionID = RevisionID()
            let run = ProcessingRun(
                id: diarizationRunID,
                meetingID: fixture.meetingID,
                kind: .diarization,
                engine: EngineDescriptor(name: "test", version: "1"),
                status: .finished
            )
            let runDirectory = fixture.library.layout.runDirectory(
                fixture.meetingID,
                runID: diarizationRunID
            )
            try FileManager.default.createDirectory(
                at: runDirectory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(run).write(
                to: fixture.library.layout.runMetadata(
                    fixture.meetingID,
                    runID: diarizationRunID
                )
            )
            try JSONEncoder().encode(DiarizationArtifact(
                jobID: completed.id,
                sourceRunID: fixture.finalASRRunID,
                revisionID: revisionID,
                tracks: []
            )).write(
                to: fixture.library.layout.runDiarization(
                    fixture.meetingID,
                    runID: diarizationRunID
                )
            )
            try await fixture.jobStore.enqueue(completed)
            _ = try await fixture.library.appendRevision(TranscriptRevision(
                id: revisionID,
                meetingID: fixture.meetingID,
                origin: .finalRun(diarizationRunID),
                turns: [TranscriptTurn(
                    start: 0,
                    end: 1,
                    segments: [TranscriptSegment(
                        text: "Separated",
                        start: 0,
                        end: 1,
                        words: [TranscriptWord(text: "Separated", start: 0, end: 1)]
                    )]
                )]
            ))

            #expect(
                try await MeetingDiarizationRequest.status(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .completed
            )
        }
    }

    @Test("a run chain deeper than diarization to final-ASR is rejected")
    func damagedRunChainHasAHardDepthLimit() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeCurrentFinalASRFixture(at: root)
            let revisionID = RevisionID()
            let innerRunID = RunID()
            let outerRunID = RunID()
            try writeFinishedDiarizationRun(
                library: fixture.library,
                meetingID: fixture.meetingID,
                runID: innerRunID,
                sourceRunID: fixture.finalASRRunID,
                revisionID: RevisionID()
            )
            try writeFinishedDiarizationRun(
                library: fixture.library,
                meetingID: fixture.meetingID,
                runID: outerRunID,
                sourceRunID: innerRunID,
                revisionID: revisionID
            )
            _ = try await fixture.library.appendRevision(TranscriptRevision(
                id: revisionID,
                meetingID: fixture.meetingID,
                origin: .finalRun(outerRunID),
                turns: [TranscriptTurn(
                    start: 0,
                    end: 1,
                    segments: [TranscriptSegment(
                        text: "Damaged",
                        start: 0,
                        end: 1,
                        words: [TranscriptWord(text: "Damaged", start: 0, end: 1)]
                    )]
                )]
            ))

            #expect(
                try await MeetingDiarizationRequest.status(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .unavailable
            )

            try JSONEncoder().encode(DiarizationArtifact(
                jobID: JobID(),
                sourceRunID: outerRunID,
                revisionID: revisionID,
                tracks: []
            )).write(to: fixture.library.layout.runDiarization(
                fixture.meetingID,
                runID: outerRunID
            ))
            #expect(
                try await MeetingDiarizationRequest.status(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meetingID,
                    modelsReady: true
                ) == .unavailable
            )
        }
    }

    @Test("generic speaker processing cannot create an unpinned imported job")
    func importedMeetingRequiresImportedRetry() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)

            await #expect(
                throws: MeetingProcessingRequestError.importedRetryRequired(
                    fixture.meeting.id
                )
            ) {
                _ = try await DiarizationRequest.enqueue(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meeting.id
                )
            }

            #expect(try await fixture.jobStore.list().map(\.id) == [fixture.job.id])
        }
    }

    @Test("a missing voice comparison continues after finished diarization")
    func missingIdentitySuggestionIsEnqueued() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Legacy", status: .ready)
            let store = try JobStore(layout: library.layout)
            let finalASR = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                status: .finished,
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            let diarization = Job(
                kind: .diarization,
                meetingID: meeting.id,
                sourceRunID: StablePipelineIdentifiers.runID(for: finalASR),
                status: .finished,
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            )
            try await store.enqueue(finalASR)
            try await store.enqueue(diarization)
            _ = try await library.appendRevision(TranscriptRevision(
                meetingID: meeting.id,
                origin: .finalRun(StablePipelineIdentifiers.runID(for: diarization)),
                turns: []
            ))

            let first = try await DiarizationRequest.enqueueMissingIdentitySuggestion(
                library: library,
                jobStore: store,
                meetingID: meeting.id
            )
            let second = try await DiarizationRequest.enqueueMissingIdentitySuggestion(
                library: library,
                jobStore: store,
                meetingID: meeting.id
            )
            let identityJobs = try await store.list().filter {
                $0.kind == .identitySuggestion
            }

            #expect(first)
            #expect(!second)
            #expect(identityJobs.count == 1)
            #expect(
                identityJobs.first?.sourceRunID
                    == StablePipelineIdentifiers.runID(for: diarization)
            )
        }
    }

    @Test("an older diarization is not continued past a newer transcription")
    func staleDiarizationIsNotContinued() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Legacy", status: .ready)
            let store = try JobStore(layout: library.layout)
            let diarization = Job(
                kind: .diarization,
                meetingID: meeting.id,
                sourceRunID: RunID(),
                status: .finished,
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            let newerFinalASR = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                status: .finished,
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            )
            try await store.enqueue(diarization)
            try await store.enqueue(newerFinalASR)
            _ = try await library.appendRevision(TranscriptRevision(
                meetingID: meeting.id,
                origin: .finalRun(StablePipelineIdentifiers.runID(for: diarization)),
                turns: []
            ))

            #expect(
                try await !DiarizationRequest.enqueueMissingIdentitySuggestion(
                    library: library,
                    jobStore: store,
                    meetingID: meeting.id
                )
            )
        }
    }

    @Test("a finished job without a loadable review does not block repair")
    func brokenFinishedIdentitySuggestionIsReplaced() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Legacy", status: .ready)
            let store = try JobStore(layout: library.layout)
            let diarization = Job(
                kind: .diarization,
                meetingID: meeting.id,
                sourceRunID: RunID(),
                status: .finished
            )
            let diarizationRunID = StablePipelineIdentifiers.runID(for: diarization)
            let brokenFinished = Job(
                kind: .identitySuggestion,
                meetingID: meeting.id,
                sourceRunID: diarizationRunID,
                status: .finished,
                createdAt: diarization.createdAt.addingTimeInterval(1)
            )
            try await store.enqueue(diarization)
            try await store.enqueue(brokenFinished)
            _ = try await library.appendRevision(TranscriptRevision(
                meetingID: meeting.id,
                origin: .finalRun(diarizationRunID),
                turns: []
            ))

            #expect(try await DiarizationRequest.enqueueMissingIdentitySuggestion(
                library: library,
                jobStore: store,
                meetingID: meeting.id
            ))
            let identityJobs = try await store.list().filter {
                $0.kind == .identitySuggestion
            }
            #expect(identityJobs.count == 2)
            #expect(identityJobs.contains { $0.status == .queued })
        }
    }
}

private struct CurrentFinalASRFixture {
    let library: Library
    let jobStore: JobStore
    let meetingID: MeetingID
    let finalASRRunID: RunID
    let revisionID: RevisionID
}

private func writeFinishedDiarizationRun(
    library: Library,
    meetingID: MeetingID,
    runID: RunID,
    sourceRunID: RunID,
    revisionID: RevisionID
) throws {
    let directory = library.layout.runDirectory(meetingID, runID: runID)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(ProcessingRun(
        id: runID,
        meetingID: meetingID,
        kind: .diarization,
        engine: EngineDescriptor(name: "test", version: "1"),
        status: .finished
    )).write(to: library.layout.runMetadata(meetingID, runID: runID))
    try JSONEncoder().encode(DiarizationArtifact(
        jobID: JobID(),
        sourceRunID: sourceRunID,
        revisionID: revisionID,
        tracks: []
    )).write(to: library.layout.runDiarization(meetingID, runID: runID))
}

private func makeCurrentFinalASRFixture(
    at root: URL,
    importGenerationID: MeetingTransferGenerationID? = nil
) async throws -> CurrentFinalASRFixture {
    let library = try Library.open(at: root)
    let receipt = importGenerationID.map { generationID in
        MeetingTransferReceipt(
            sourceMeetingID: MeetingID(),
            sourceRevisionID: nil,
            sourcePackageContentDigest: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSinceReferenceDate: 1),
            sourceAppVersion: nil,
            includedCapabilities: [.audio, .transcript],
            sourceLocaleIdentifier: "de-DE",
            sourceLocaleOrigin: .explicit,
            importGenerationID: generationID
        )
    }
    let meeting = try await library.createMeeting(
        title: "Meeting",
        status: .ready,
        metadata: receipt.map { MeetingMetadata(transferReceipt: $0) }
    )
    let jobStore = try JobStore(layout: library.layout)
    let finalASRRunID = RunID()
    let run = ProcessingRun(
        id: finalASRRunID,
        meetingID: meeting.id,
        kind: .finalASR,
        engine: EngineDescriptor(name: "test", version: "1"),
        status: .finished
    )
    let runDirectory = library.layout.runsDirectory(meeting.id).appending(
        path: finalASRRunID.description,
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(run).write(
        to: runDirectory.appending(path: "run.json")
    )
    let segment = TranscriptSegment(
        text: "Hello",
        start: 0,
        end: 1,
        words: [TranscriptWord(text: "Hello", start: 0, end: 1)]
    )
    let revision = TranscriptRevision(
        meetingID: meeting.id,
        origin: .finalRun(finalASRRunID),
        turns: [TranscriptTurn(start: 0, end: 1, segments: [segment])]
    )
    _ = try await library.appendRevision(revision)
    return CurrentFinalASRFixture(
        library: library,
        jobStore: jobStore,
        meetingID: meeting.id,
        finalASRRunID: finalASRRunID,
        revisionID: revision.id
    )
}
