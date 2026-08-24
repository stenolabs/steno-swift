import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("JobStore")
struct JobStoreTests {
    @Test("job status mutations read and write within one library transaction")
    func statusMutationsUseOneTransaction() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .processing
            )
            let setup = try JobStore(layout: library.layout)
            let direct = Job(kind: .finalASR, meetingID: meeting.id)
            let claimed = Job(kind: .diarization, meetingID: meeting.id)
            let recovered = Job(kind: .export, meetingID: meeting.id)
            let failed = Job(kind: .templateRender, meetingID: meeting.id)
            for job in [direct, claimed, recovered, failed] {
                try await setup.enqueue(job)
            }
            _ = try await setup.transition(recovered.id, to: .running)
            _ = try await setup.transition(failed.id, to: .running)
            _ = try await setup.transition(
                failed.id,
                to: .failed,
                failureReason: .diarizationModelsNotInstalled
            )

            let recorder = JobMutationCheckpointRecorder()
            let store = try JobStore(
                layout: library.layout,
                mutationAction: { checkpoint, transaction in
                    try transaction.validate(layout: library.layout)
                    recorder.record(checkpoint)
                }
            )

            _ = try await store.transition(direct.id, to: .running)
            #expect(try await store.claimNext(kind: .diarization)?.id == claimed.id)
            _ = try await store.recoverAtLaunch()
            _ = try await store.requeueFailedJobs(
                kind: .templateRender,
                failureReason: .diarizationModelsNotInstalled
            )

            #expect(recorder.values == [
                .afterExclusiveTransactionBeforeTransitionRead,
                .afterExclusiveTransactionBeforeClaimScan,
                .afterExclusiveTransactionBeforeRecoveryScan,
                .afterExclusiveTransactionBeforeRequeueScan,
            ])
        }
    }

    @Test("launch recovery leaves a job claimed by another store running")
    func recoverySkipsActivelyClaimedJob() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .processing
            )
            let owner = try JobStore(layout: library.layout)
            let recovery = try JobStore(layout: library.layout)
            let job = Job(kind: .finalASR, meetingID: meeting.id)
            try await owner.enqueue(job)

            #expect(try await owner.claimNext(kind: .finalASR)?.id == job.id)
            #expect(try await recovery.recoverAtLaunch().isEmpty)
            #expect(try await recovery.load(job.id).status == .running)

            _ = try await owner.transition(job.id, to: .finished)
        }
    }

    @Test("launch recovery removes only unused terminal and orphan execution locks")
    func recoveryCleansUnusedExecutionLocks() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .processing
            )
            let owner = try JobStore(layout: library.layout)
            let recovery = try JobStore(layout: library.layout)
            let active = Job(kind: .finalASR, meetingID: meeting.id)
            let finished = Job(kind: .diarization, meetingID: meeting.id)
            try await owner.enqueue(active)
            try await owner.enqueue(finished)
            _ = try await owner.claimNext(kind: .finalASR)
            _ = try await owner.claimNext(kind: .diarization)
            _ = try await owner.transition(finished.id, to: .finished)

            let activeLock = library.layout.jobsDirectory.appendingPathComponent(
                ".\(active.id).execution-lock"
            )
            let finishedLock = library.layout.jobsDirectory.appendingPathComponent(
                ".\(finished.id).execution-lock"
            )
            let orphanLock = library.layout.jobsDirectory.appendingPathComponent(
                ".\(JobID()).execution-lock"
            )
            try Data().write(to: orphanLock)

            _ = try await recovery.recoverAtLaunch()

            #expect(FileManager.default.fileExists(atPath: activeLock.path))
            #expect(!FileManager.default.fileExists(atPath: finishedLock.path))
            #expect(!FileManager.default.fileExists(atPath: orphanLock.path))
            #expect(try await recovery.load(active.id).status == .running)

            _ = try await owner.transition(active.id, to: .finished)
        }
    }

    @Test("persists transitions and counts execution attempts")
    func transitions() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let store = try JobStore(layout: library.layout)
            let job = Job(kind: .finalASR, meetingID: meeting.id)
            try await store.enqueue(job)

            let running = try await store.transition(job.id, to: .running)
            let finished = try await store.transition(job.id, to: .finished)

            #expect(running.attemptCount == 1)
            #expect(finished.status == .finished)
            #expect(try await store.load(job.id) == finished)
            #expect(try await store.list().map(\.id) == [job.id])
        }
    }

    @Test("cancellation cannot overwrite a job that was already claimed")
    func cancellationDoesNotUseAStaleQueuedState() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .processing
            )
            let store = try JobStore(layout: library.layout)
            let job = Job(kind: .finalASR, meetingID: meeting.id)
            try await store.enqueue(job)
            #expect(try await store.claimNext(kind: .finalASR)?.id == job.id)

            let cancellation = try await store.cancelIfQueuedOrFailed(job.id)

            #expect(cancellation == nil)
            #expect(try await store.load(job.id).status == .running)
        }
    }

    @Test("failure reasons persist only while a job is failed")
    func failureReasonLifecycle() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let store = try JobStore(layout: library.layout)
            let job = Job(kind: .diarization, meetingID: meeting.id)
            try await store.enqueue(job)
            _ = try await store.transition(job.id, to: .running)

            let failed = try await store.transition(
                job.id,
                to: .failed,
                errorMessage: "Models missing",
                failureReason: .diarizationModelsNotInstalled
            )
            let requeued = try await store.transition(job.id, to: .queued)

            #expect(failed.failureReason == .diarizationModelsNotInstalled)
            #expect(requeued.failureReason == nil)
            #expect(requeued.errorMessage == nil)
        }
    }

    @Test("launch recovery requeues running jobs and preserves completed jobs")
    func recoverAtLaunch() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let store = try JobStore(layout: library.layout)
            let runningJob = Job(kind: .finalASR, meetingID: meeting.id)
            let finishedJob = Job(
                kind: .export,
                meetingID: meeting.id,
                status: .finished,
                attemptCount: 1
            )
            try await store.enqueue(runningJob)
            _ = try await store.transition(runningJob.id, to: .running)
            try await store.enqueue(finishedJob)

            let recovered = try await store.recoverAtLaunch()

            #expect(recovered.map(\.id) == [runningJob.id])
            #expect(try await store.load(runningJob.id).status == .queued)
            #expect(try await store.load(runningJob.id).attemptCount == 1)
            #expect(try await store.load(finishedJob.id).status == .finished)
        }
    }

    @Test("equivalent jobs are enqueued atomically")
    func equivalentJobsAreEnqueuedAtomically() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let store = try JobStore(layout: library.layout)
            let sourceRunID = RunID()
            let first = Job(
                kind: .diarization,
                meetingID: meeting.id,
                sourceRunID: sourceRunID
            )
            let second = Job(
                kind: .diarization,
                meetingID: meeting.id,
                sourceRunID: sourceRunID
            )

            async let firstResult = store.enqueueIfNoEquivalentJob(
                first,
                blockingStatuses: [.queued, .running, .finished]
            )
            async let secondResult = store.enqueueIfNoEquivalentJob(
                second,
                blockingStatuses: [.queued, .running, .finished]
            )
            let results = try await [firstResult, secondResult]

            #expect(results.filter { $0 }.count == 1)
            #expect(try await store.list().count == 1)
        }
    }

    @Test("report jobs deduplicate only for the complete pinned input identity")
    func reportJobsUseCompletePinnedIdentity() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .processing
            )
            let store = try JobStore(layout: library.layout)
            let sourceRunID = RunID()
            let revisionID = RevisionID()
            let importGenerationID = MeetingTransferGenerationID()
            let baseline = Job(
                kind: .templateRender,
                meetingID: meeting.id,
                sourceRunID: sourceRunID,
                templateID: "minutes",
                revisionID: revisionID,
                textModelEndpointID: "endpoint-a",
                templateRenderInputFingerprint: "sha256:baseline",
                importGenerationID: importGenerationID
            )

            let inserted = try await store.enqueueOrExistingEquivalentJob(
                baseline,
                blockingStatuses: [.queued, .running]
            )
            let equivalent = try await store.enqueueOrExistingEquivalentJob(
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "minutes",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: importGenerationID
                ),
                blockingStatuses: [.queued, .running]
            )
            let variants = [
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "other-template",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: importGenerationID
                ),
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "minutes",
                    revisionID: RevisionID(),
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: importGenerationID
                ),
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "minutes",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-b",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: importGenerationID
                ),
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "minutes",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:changed",
                    importGenerationID: importGenerationID
                ),
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: RunID(),
                    templateID: "minutes",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: importGenerationID
                ),
                Job(
                    kind: .templateRender,
                    meetingID: meeting.id,
                    sourceRunID: sourceRunID,
                    templateID: "minutes",
                    revisionID: revisionID,
                    textModelEndpointID: "endpoint-a",
                    templateRenderInputFingerprint: "sha256:baseline",
                    importGenerationID: MeetingTransferGenerationID()
                ),
            ]
            var returnedVariantIDs: [JobID] = []
            for variant in variants {
                returnedVariantIDs.append(
                    try await store.enqueueOrExistingEquivalentJob(
                        variant,
                        blockingStatuses: [.queued, .running]
                    ).id
                )
            }

            #expect(inserted.id == baseline.id)
            #expect(equivalent.id == baseline.id)
            #expect(Set(returnedVariantIDs).count == variants.count)
            #expect(!returnedVariantIDs.contains(baseline.id))
            #expect(try await store.list().count == variants.count + 1)
        }
    }

    @Test("report job equivalence includes the pinned endpoint configuration")
    func reportJobEquivalenceIncludesEndpointSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .ready
            )
            let store = try JobStore(layout: library.layout)
            let endpointID = UUID()
            let original = TextModelEndpointSnapshot(
                id: endpointID,
                name: "Endpoint",
                baseURL: URL(string: "https://old.example.test/v1")!,
                modelID: "model",
                requiresAPIKey: true
            )
            let changed = TextModelEndpointSnapshot(
                id: endpointID,
                name: "Endpoint",
                baseURL: URL(string: "https://new.example.test/v1")!,
                modelID: "model",
                requiresAPIKey: true
            )
            let baseline = Job(
                kind: .templateRender,
                meetingID: meeting.id,
                textModelEndpointID: endpointID.uuidString,
                textModelEndpointSnapshot: original,
                templateRenderInputFingerprint: "sha256:input"
            )
            let mutation = Job(
                kind: .templateRender,
                meetingID: meeting.id,
                textModelEndpointID: endpointID.uuidString,
                textModelEndpointSnapshot: changed,
                templateRenderInputFingerprint: "sha256:input"
            )

            let first = try await store.enqueueOrExistingEquivalentJob(
                baseline,
                blockingStatuses: [.queued, .running]
            )
            let second = try await store.enqueueOrExistingEquivalentJob(
                mutation,
                blockingStatuses: [.queued, .running]
            )

            #expect(first.id == baseline.id)
            #expect(second.id == mutation.id)
            #expect(try await store.list().count == 2)
        }
    }

    @Test("report job equivalence includes the endpoint configuration revision")
    func reportJobEquivalenceIncludesEndpointRevision() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Meeting",
                status: .ready
            )
            let store = try JobStore(layout: library.layout)
            let endpointID = UUID()
            let original = TextModelEndpointSnapshot(
                id: endpointID,
                name: "Endpoint",
                baseURL: URL(string: "https://models.example.test/v1")!,
                modelID: "model",
                requiresAPIKey: true,
                configurationRevision: UUID()
            )
            let replacement = TextModelEndpointSnapshot(
                id: endpointID,
                name: original.name,
                baseURL: original.baseURL,
                modelID: original.modelID,
                requiresAPIKey: original.requiresAPIKey,
                configurationRevision: UUID()
            )
            let baseline = Job(
                kind: .templateRender,
                meetingID: meeting.id,
                textModelEndpointID: endpointID.uuidString,
                textModelEndpointSnapshot: original,
                templateRenderInputFingerprint: "sha256:input"
            )
            let mutation = Job(
                kind: .templateRender,
                meetingID: meeting.id,
                textModelEndpointID: endpointID.uuidString,
                textModelEndpointSnapshot: replacement,
                templateRenderInputFingerprint: "sha256:input"
            )

            let first = try await store.enqueueOrExistingEquivalentJob(
                baseline,
                blockingStatuses: [.queued, .running]
            )
            let second = try await store.enqueueOrExistingEquivalentJob(
                mutation,
                blockingStatuses: [.queued, .running]
            )

            #expect(first.id == baseline.id)
            #expect(second.id == mutation.id)
            #expect(first.id != second.id)
        }
    }
}

private final class JobMutationCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [JobStoreMutationCheckpoint] = []

    var values: [JobStoreMutationCheckpoint] {
        lock.withLock { storedValues }
    }

    func record(_ value: JobStoreMutationCheckpoint) {
        lock.withLock { storedValues.append(value) }
    }
}

@Suite("RecoverySweep")
struct RecoverySweepTests {
    @Test("a draft without a recording is never collected as stranded")
    func draftsAreLeftAlone() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let draft = try await library.createMeeting(title: "Nächster Kreistag", status: .draft)
            let store = try JobStore(layout: library.layout)

            let sweep = try await RecoverySweep.run(library: library, jobStore: store)

            #expect(sweep.isEmpty)
            #expect(try await library.loadMeeting(draft.id).status == .draft)
            #expect(try await store.list().isEmpty)
        }
    }

    @Test("interrupts inactive recordings; finalization only with registered assets")
    func recoverRecordings() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let inactive = try await library.createMeeting(title: "Inactive", status: .recording)
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )
            let sourceLocale = try MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            )
            let withAssets = try await library.createMeeting(
                title: "WithAssets",
                status: .recording,
                sourceLocale: sourceLocale,
                transcriptionPlan: plan
            )
            let active = try await library.createMeeting(title: "Active", status: .recording)
            _ = try await library.createMeeting(title: "Ready", status: .ready)
            let store = try JobStore(layout: library.layout)

            let source = root.appendingPathComponent("track.caf")
            try Data([0x63, 0x61, 0x66, 0x66]).write(to: source)
            _ = try await library.registerMediaAsset(
                for: withAssets.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: 1
            )

            let firstSweep = try await RecoverySweep.run(
                library: library,
                jobStore: store,
                activeMeetingIDs: [active.id]
            )
            let secondSweep = try await RecoverySweep.run(
                library: library,
                jobStore: store,
                activeMeetingIDs: [active.id]
            )
            let jobs = try await store.list()

            #expect(Set(firstSweep) == [inactive.id, withAssets.id])
            #expect(secondSweep.isEmpty)
            #expect(try await library.loadMeeting(inactive.id).status == .interrupted)
            #expect(try await library.loadMeeting(active.id).status == .recording)
            // Ohne Originalspuren kein Finalisierungsjob (die Adoption der
            // Capture-Dateien reiht ihn ein); mit Spuren genau einer.
            #expect(jobs.count == 1)
            #expect(jobs.first?.kind == .finalASR)
            #expect(jobs.first?.meetingID == withAssets.id)
            #expect(jobs.first?.transcriptionProviderID == .parakeetTDTv3)
            #expect(jobs.first?.localeIdentifier == "de-DE")
        }
    }
}
