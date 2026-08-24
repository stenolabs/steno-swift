import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import Testing

@Suite("Diarization and identity pipeline")
struct PipelineIntegrationTests {
    @Test("speaker separation keeps an edit visible until the user adopts its labels")
    func editedTranscriptRequiresExplicitDiarizationAdoption() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let missingModels = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .modelsMissing),
                locale: Locale(identifier: "de-DE")
            )
            await missingModels.start()
            try await missingModels.waitUntilIdle()
            await missingModels.stop()

            let finalASR = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )
            let edited = try TranscriptEdit.replacingText(
                in: finalASR,
                turnIndex: 0,
                with: "Edited decision"
            )
            _ = try await fixture.library.appendRevision(edited)
            #expect(
                try await MeetingDiarizationRequest.request(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meeting.id,
                    modelsReady: true
                ) == .queued
            )

            let resumed = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            await resumed.start()
            try await resumed.waitUntilIdle()

            let pointer = try await fixture.library.loadCurrentRevisionPointer(
                meetingID: fixture.meeting.id
            )
            let pendingID = try #require(pointer.pendingCandidate)
            let pending = try await fixture.library.loadRevision(
                pendingID,
                meetingID: fixture.meeting.id
            )
            #expect(pointer.currentRevisionID == edited.id)
            #expect(try await MeetingDiarizationRequest.status(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                modelsReady: true
            ) == .resultsPending)
            #expect(pending.turns.allSatisfy {
                if case .cluster = $0.speaker { return true }
                return false
            })

            let newerEdit = try TranscriptEdit.replacingText(
                in: edited,
                turnIndex: 0,
                with: "Newer decision"
            )
            _ = try await fixture.library.appendRevision(newerEdit)
            #expect(try await MeetingDiarizationRequest.adoptPendingResult(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                expectedCurrentRevisionID: edited.id,
                modelsReady: true
            ) == .resultsPending)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == newerEdit)

            #expect(try await MeetingDiarizationRequest.adoptPendingResult(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                expectedCurrentRevisionID: newerEdit.id,
                modelsReady: true
            ) == .completed)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == pending)
            #expect(try await fixture.library.loadRevision(
                edited.id,
                meetingID: fixture.meeting.id
            ) == edited)
            #expect(try await fixture.library.loadRevision(
                newerEdit.id,
                meetingID: fixture.meeting.id
            ) == newerEdit)
            await resumed.stop()
        }
    }

    @Test("chains final ASR through diarization and advisory identity suggestions")
    func completeJobChain() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let transcription = FakeTranscriptionProvider(behavior: .succeed)
            let diarization = FakeDiarizationProvider(behavior: .succeed)
            let personID = PersonID()
            let identityStore = try IdentityStore(layout: fixture.library.layout)
            try await replacePersonsForTest([
                Person(
                    id: personID,
                    displayName: "Ada",
                    prototypes: [
                        prototype(personID: personID, meetingID: MeetingID()),
                        prototype(personID: personID, meetingID: MeetingID()),
                    ]
                ),
            ], in: identityStore)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: transcription),
                diarizationProvider: diarization,
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let jobs = try await fixture.jobStore.list()
            let runs = try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )
            let diarizationRun = try #require(runs.first { $0.kind == .diarization })
            let identityRun = try #require(runs.first { $0.kind == .identitySuggestion })
            let artifact = try loadDiarizationArtifact(
                library: fixture.library,
                meetingID: fixture.meeting.id,
                runID: diarizationRun.id
            )
            let suggestions = try loadIdentitySuggestionArtifact(
                library: fixture.library,
                meetingID: fixture.meeting.id,
                runID: identityRun.id
            )
            let revision = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )

            #expect(jobs.map(\.kind) == [.finalASR, .diarization, .identitySuggestion])
            #expect(jobs.allSatisfy { $0.status == .finished })
            #expect(Set(runs.map(\.kind)) == [.finalASR, .diarization, .identitySuggestion])
            #expect(await transcription.callCount() == 2)
            #expect(await diarization.callCount() == 2)
            #expect(artifact.tracks.count == 2)
            #expect(artifact.tracks.allSatisfy { $0.clusters.count == 1 })
            #expect(artifact.tracks.allSatisfy { $0.clusters[0].embedding.count == 2 })
            #expect(artifact.tracks.allSatisfy { $0.clusters[0].segmentCount == 1 })
            #expect(artifact.tracks.allSatisfy { $0.clusters[0].speechDurationSeconds == 1 })
            #expect(suggestions.suggestions.count == 2)
            #expect(suggestions.suggestions.first {
                $0.channel == MediaAsset.Kind.micTrack.rawValue
            }?.suggestedPersonID == personID)
            #expect(suggestions.clusterResolutions.count == 2)
            #expect(!suggestions.identityEvidenceFingerprint.isEmpty)
            #expect(revision.id == artifact.revisionID)
            #expect(revision.origin == .finalRun(diarizationRun.id))
            #expect(revision.turns.allSatisfy {
                if case .cluster(let runID, _) = $0.speaker {
                    return runID == diarizationRun.id
                }
                return false
            })
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            await coordinator.stop()
        }
    }

    private func prototype(
        personID: PersonID,
        meetingID: MeetingID
    ) -> SpeakerPrototype {
        SpeakerPrototype(
            personID: personID,
            embedding: [1, 0],
            recordingType: .inPerson,
            channel: MediaAsset.Kind.micTrack.rawValue,
            meetingID: meetingID,
            runID: RunID(),
            clusterID: "known",
            speechDurationSeconds: 30,
            segmentCount: 5,
            source: .userConfirmed
        )
    }

    @Test("recovers interrupted diarization and replays a committed run without duplicate revision")
    func diarizationCrashRecoveryIsIdempotent() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let blocking = FakeDiarizationProvider(behavior: .block)
            let interrupted = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: blocking,
                locale: Locale(identifier: "de-DE")
            )
            await interrupted.start()
            try await eventually {
                let jobs = try await fixture.jobStore.list()
                let callCount = await blocking.callCount()
                return jobs.contains { $0.kind == .diarization && $0.status == .running }
                    && callCount == 1
            }
            let interruptedJob = try #require(try await fixture.jobStore.list().first {
                $0.kind == .diarization
            })
            try await simulateAbruptExit(
                of: interrupted,
                whileRunning: interruptedJob.id,
                jobStore: fixture.jobStore,
                library: fixture.library
            )
            #expect(interruptedJob.status == .running)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 1)

            let resumedProvider = FakeDiarizationProvider(behavior: .succeed)
            let resumed = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: resumedProvider,
                locale: Locale(identifier: "de-DE")
            )
            try await resumed.coordinator.waitUntilIdle()

            let finishedJob = try await resumed.jobStore.load(interruptedJob.id)
            #expect(finishedJob.status == .finished)
            #expect(finishedJob.attemptCount == 2)
            #expect(await resumedProvider.callCount() == 2)
            #expect(try revisionDocuments(
                library: resumed.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            await resumed.coordinator.stop()

            try overwriteJob(
                finishedJob,
                status: .running,
                layout: resumed.library.layout
            )
            let providerThatMustNotRun = FakeDiarizationProvider(behavior: .fail)
            let replayed = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: providerThatMustNotRun,
                locale: Locale(identifier: "de-DE")
            )
            try await replayed.coordinator.waitUntilIdle()

            #expect(try await replayed.jobStore.load(interruptedJob.id).status == .finished)
            #expect(await providerThatMustNotRun.callCount() == 0)
            #expect(try revisionDocuments(
                library: replayed.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            await replayed.coordinator.stop()
        }
    }

    @Test("cancelling diarization removes partial artifacts and does not enqueue identity")
    func cancelsDiarization() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let diarization = FakeDiarizationProvider(behavior: .block)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: diarization,
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await eventually {
                try await fixture.jobStore.list().contains {
                    $0.kind == .diarization && $0.status == .running
                }
            }
            let job = try #require(try await fixture.jobStore.list().first {
                $0.kind == .diarization
            })

            try await coordinator.cancel(jobID: job.id)
            try await coordinator.waitUntilIdle()

            let jobs = try await fixture.jobStore.list()
            let current = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )
            let finalRun = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .finalASR })
            #expect(try await fixture.jobStore.load(job.id).status == .cancelled)
            #expect(!jobs.contains { $0.kind == .identitySuggestion })
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(current.origin == .finalRun(finalRun.id))
            await coordinator.stop()
        }
    }

    @Test("a diarization provider error keeps the final ASR revision current")
    func diarizationFailurePreservesRevision() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let jobs = try await fixture.jobStore.list()
            let diarizationJob = try #require(jobs.first { $0.kind == .diarization })
            let current = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )
            let failedRun = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .diarization })

            #expect(diarizationJob.status == .failed)
            #expect(diarizationJob.errorMessage == "Fake diarization provider failed.")
            #expect(failedRun.status == .failed)
            #expect(!jobs.contains { $0.kind == .identitySuggestion })
            #expect(current.origin != .finalRun(failedRun.id))
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 1)
            await coordinator.stop()
        }
    }

    @Test("missing diarization models persist a retryable typed failure")
    func missingDiarizationModelsAreTyped() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .modelsMissing),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let job = try #require(try await fixture.jobStore.list().first {
                $0.kind == .diarization
            })
            #expect(job.status == .failed)
            #expect(job.failureReason == .diarizationModelsNotInstalled)
            await coordinator.stop()
        }
    }
}

private func loadDiarizationArtifact(
    library: Library,
    meetingID: MeetingID,
    runID: RunID
) throws -> DiarizationArtifact {
    try JSONDecoder().decode(
        DiarizationArtifact.self,
        from: Data(contentsOf: library.layout.runDiarization(meetingID, runID: runID))
    )
}

private func loadIdentitySuggestionArtifact(
    library: Library,
    meetingID: MeetingID,
    runID: RunID
) throws -> IdentitySuggestionArtifact {
    try JSONDecoder().decode(
        IdentitySuggestionArtifact.self,
        from: Data(contentsOf: library.layout.runSuggestions(meetingID, runID: runID))
    )
}
