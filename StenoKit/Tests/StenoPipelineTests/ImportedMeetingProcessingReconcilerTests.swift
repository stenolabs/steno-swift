import Foundation
import StenoDomain
import StenoExchange
@testable import StenoLibrary
@testable import StenoPipeline
import Synchronization
import Testing

@Suite("Imported meeting processing reconciler")
struct ImportedMeetingProcessingReconcilerTests {
    @Test("independent JobStore actors cannot overwrite a racing job identity")
    func independentStoresPreserveOneIdentity() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let barrier = JobEnsureRaceBarrier(expectedArrivals: 2)
            let firstStore = try JobStore(
                layout: library.layout,
                ensureCheckpoint: { checkpoint in
                    guard checkpoint == .afterMissingIdentityBeforeInsert else { return }
                    barrier.arriveAndWait()
                }
            )
            let secondStore = try JobStore(
                layout: library.layout,
                ensureCheckpoint: { checkpoint in
                    guard checkpoint == .afterMissingIdentityBeforeInsert else { return }
                    barrier.arriveAndWait()
                }
            )
            let sharedID = JobID()
            let first = Job(
                id: sharedID,
                kind: .finalASR,
                meetingID: MeetingID(),
                localeIdentifier: "de-DE"
            )
            let second = Job(
                id: sharedID,
                kind: .finalASR,
                meetingID: MeetingID(),
                localeIdentifier: "de-DE"
            )

            async let firstAttempt = ensureAttempt(first, store: firstStore)
            async let secondAttempt = ensureAttempt(second, store: secondStore)
            let attempts = await [firstAttempt, secondAttempt]

            #expect(attempts.filter { $0 == .inserted }.count == 1)
            #expect(attempts.filter { $0 == .identityConflict }.count == 1)
            let persisted = try #require(try await firstStore.list().only)
            #expect(persisted == first || persisted == second)
        }
    }

    @Test("ensureEnqueued inserts once and requires exact identity")
    func ensureEnqueuedIsIdempotent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try JobStore(layout: library.layout)
            let job = Job(
                id: JobID(),
                kind: .finalASR,
                meetingID: MeetingID(),
                localeIdentifier: "de-DE",
                importGenerationID: MeetingTransferGenerationID()
            )

            #expect(try await store.ensureEnqueued(job) == .inserted)
            #expect(try await store.ensureEnqueued(job) == .alreadyMatching)
            #expect(try await store.list() == [job])

            let generationConflict = Job(
                id: job.id,
                kind: job.kind,
                meetingID: job.meetingID,
                localeIdentifier: job.localeIdentifier,
                importGenerationID: MeetingTransferGenerationID(),
                createdAt: job.createdAt
            )
            do {
                _ = try await store.ensureEnqueued(generationConflict)
                Issue.record("expected generation identity conflict")
            } catch let error as LibraryError {
                guard case .jobIdentityConflict(let jobID) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(jobID == job.id)
            }

            let conflicting = Job(
                id: job.id,
                kind: .finalASR,
                meetingID: MeetingID(),
                localeIdentifier: "de-DE",
                importGenerationID: job.importGenerationID,
                createdAt: job.createdAt
            )
            do {
                _ = try await store.ensureEnqueued(conflicting)
                Issue.record("expected job identity conflict")
            } catch let error as LibraryError {
                guard case .jobIdentityConflict(let jobID) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(jobID == job.id)
            }
            #expect(try await store.list() == [job])
        }
    }

    @Test("persisted processing request enqueues its preassigned job and advances state")
    func reconcilesPersistedRequest() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )

            try await context.reconciler.reconcileAll()

            let job = try #require(try await context.jobStore.list().first)
            #expect(job.id == request.jobID)
            #expect(job.meetingID == request.meetingID)
            #expect(job.kind == .finalASR)
            #expect(job.localeIdentifier == request.localeIdentifier)
            #expect(job.importGenerationID == context.generationID)
            #expect(job.createdAt == request.createdAt)
            #expect(try await context.stateStore.load(context.meetingID) == .jobEnqueued(
                jobID: request.jobID,
                localeIdentifier: request.localeIdentifier
            ))
        }
    }

    @Test("two concurrent reconcilers persist exactly one preassigned job")
    func concurrentReconcilersCreateOneJob() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )
            let second = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: context.stateStore,
                jobStore: context.jobStore
            )

            async let firstRun: Void = context.reconciler.reconcileAll()
            async let secondRun: Void = second.reconcileAll()
            _ = try await (firstRun, secondRun)

            let jobs = try await context.jobStore.list()
            #expect(jobs.count == 1)
            #expect(jobs[0].id == request.jobID)
        }
    }

    @Test("fresh retry supersedes a stale reconciler candidate before enqueue")
    func freshRetrySupersedesStaleReconcilerCandidate() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let staleRequest = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(staleRequest),
                for: context.meetingID
            )
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: context.meetingID,
                receipt: try await context.library.loadMeeting(context.meetingID)
                    .metadata!.transferReceipt!,
                to: context.library.layout.transferCommitPending(context.meetingID)
            )
            let retryToken = try #require(
                try await context.stateStore.freshImportRetryToken(context.meetingID)
            )
            let pause = ReconcilerGroupPause(expectedArrivals: 2)
            let secondLibrary = try Library.open(at: root)
            let firstStaleReconciler = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: MeetingTransferStateStore(layout: context.library.layout),
                jobStore: try JobStore(layout: context.library.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .afterCandidateStateReadBeforeTransaction else {
                        return
                    }
                    pause.arriveAndWait()
                }
            )
            let secondStaleReconciler = ImportedMeetingProcessingReconciler(
                library: secondLibrary,
                stateStore: MeetingTransferStateStore(layout: secondLibrary.layout),
                jobStore: try JobStore(layout: secondLibrary.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .afterCandidateStateReadBeforeTransaction else {
                        return
                    }
                    pause.arriveAndWait()
                }
            )

            async let firstReconciliation: Void = firstStaleReconciler.reconcileAll()
            async let secondReconciliation: Void = secondStaleReconciler.reconcileAll()
            try await eventually { pause.allArrived }
            #expect(try await context.stateStore.resolveFreshImportRetry(
                .importedOnly,
                for: context.meetingID,
                expected: retryToken
            ))
            pause.release()
            _ = try await (firstReconciliation, secondReconciliation)

            #expect(try await context.jobStore.list().isEmpty)
            #expect(try await context.stateStore.load(context.meetingID) == .importedOnly)
            #expect(try await !context.stateStore.requiresFreshImportRetry(context.meetingID))
        }
    }

    @Test("fresh retry enqueues only its newly selected request")
    func freshRetryNewRequestSupersedesStaleReconcilerCandidate() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let staleRequest = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            let selectedRequest = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: context.meetingID,
                localeIdentifier: "fr-FR",
                createdAt: Date(timeIntervalSinceReferenceDate: 43),
                importGenerationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(staleRequest),
                for: context.meetingID
            )
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: context.meetingID,
                receipt: try await context.library.loadMeeting(context.meetingID)
                    .metadata!.transferReceipt!,
                to: context.library.layout.transferCommitPending(context.meetingID)
            )
            let retryToken = try #require(
                try await context.stateStore.freshImportRetryToken(context.meetingID)
            )
            let pause = ReconcilerPause()
            let staleReconciler = ImportedMeetingProcessingReconciler(
                library: try Library.open(at: root),
                stateStore: MeetingTransferStateStore(layout: context.library.layout),
                jobStore: try JobStore(layout: context.library.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .afterCandidateStateReadBeforeTransaction else {
                        return
                    }
                    pause.arriveAndWait()
                }
            )

            let staleReconciliation = Task { try await staleReconciler.reconcileAll() }
            try await eventually { pause.hasArrived }
            #expect(try await context.stateStore.resolveFreshImportRetry(
                .processingRequested(selectedRequest),
                for: context.meetingID,
                expected: retryToken
            ))
            try await context.reconciler.reconcileAll()
            pause.release()
            try await staleReconciliation.value

            let jobs = try await context.jobStore.list()
            #expect(jobs.map(\.id) == [selectedRequest.jobID])
            #expect(jobs[0].localeIdentifier == "fr-FR")
            #expect(try await context.stateStore.load(context.meetingID) == .jobEnqueued(
                jobID: selectedRequest.jobID,
                localeIdentifier: "fr-FR"
            ))
        }
    }

    @Test("crash after enqueue before state update recovers without duplicate job")
    func recoversAfterEnqueueCrash() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )
            let crashing = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: context.stateStore,
                jobStore: context.jobStore,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterEnsureEnqueuedBeforeStateUpdate else { return }
                    throw ReconcilerTestError.crash
                }
            )

            await #expect(throws: ReconcilerTestError.crash) {
                try await crashing.reconcileAll()
            }
            #expect(try await context.jobStore.list().map(\.id) == [request.jobID])
            #expect(try await context.stateStore.load(context.meetingID)
                == .processingRequested(request))

            try await context.reconciler.reconcileAll()
            #expect(try await context.jobStore.list().map(\.id) == [request.jobID])
            #expect(try await context.stateStore.load(context.meetingID) == .jobEnqueued(
                jobID: request.jobID,
                localeIdentifier: request.localeIdentifier
            ))
        }
    }

    @Test("reconciler revalidates a newer manual-retry state before enqueue")
    func reconcileStateAdvanceUsesExpectedStateCAS() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )
            let pause = ReconcilerPause()
            let reconciler = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: context.stateStore,
                jobStore: context.jobStore,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterCandidateStateReadBeforeTransaction else {
                        return
                    }
                    pause.arriveAndWait()
                }
            )

            let reconciliation = Task { try await reconciler.reconcileAll() }
            try await eventually { pause.hasArrived }
            let replacement: ImportedMeetingProcessingState = .needsManualRetry(
                jobID: request.jobID,
                localeIdentifier: request.localeIdentifier,
                reason: "Newer local decision"
            )
            let otherStore = MeetingTransferStateStore(layout: context.library.layout)
            #expect(try await otherStore.compareAndSet(
                expected: .processingRequested(request),
                newState: replacement,
                for: context.meetingID
            ) == .updated)
            pause.release()
            try await reconciliation.value

            #expect(try await context.stateStore.load(context.meetingID) == replacement)
            #expect(try await context.jobStore.list().isEmpty)
        }
    }

    @Test("terminal matching jobs are acknowledged but never automatically requeued")
    func terminalJobsAreNeverRequeued() async throws {
        for status in [Job.Status.failed, .cancelled, .finished] {
            try await withTemporaryDirectory { root in
                let context = try await makeReconcilerContext(at: root)
                let request = makeProcessingRequest(
                    meetingID: context.meetingID,
                    generationID: context.generationID
                )
                try await context.stateStore.save(
                    .processingRequested(request),
                    for: context.meetingID
                )
                let terminal = Job(
                    id: request.jobID,
                    kind: .finalASR,
                    meetingID: request.meetingID,
                    localeIdentifier: request.localeIdentifier,
                    importGenerationID: request.importGenerationID,
                    status: status,
                    createdAt: request.createdAt
                )
                try await context.jobStore.enqueue(terminal)

                try await context.reconciler.reconcileAll()

                #expect(try await context.jobStore.list() == [terminal])
                #expect(try await context.stateStore.load(context.meetingID)
                    == .jobEnqueued(
                        jobID: request.jobID,
                        localeIdentifier: request.localeIdentifier
                    ))
            }
        }
    }

    @Test("states without a processing request never create a job")
    func ignoresNonRequestStates() async throws {
        for state in [
            ImportedMeetingProcessingState.importedOnly,
            .awaitingLanguageConfirmation,
            .awaitingModel(localeIdentifier: "de-DE"),
            .needsManualRetry(
                jobID: JobID(),
                localeIdentifier: "de-DE",
                reason: "Local failure"
            ),
        ] {
            try await withTemporaryDirectory { root in
                let context = try await makeReconcilerContext(at: root)
                try await context.stateStore.save(state, for: context.meetingID)

                try await context.reconciler.reconcileAll()

                #expect(try await context.jobStore.list().isEmpty)
                #expect(try await context.stateStore.load(context.meetingID) == state)
            }
        }
    }

    @Test("manual retry creates new request and job identifiers")
    func manualRetryUsesNewIdentifiers() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let oldJob = Job(
                kind: .finalASR,
                meetingID: context.meetingID,
                localeIdentifier: "de-DE",
                importGenerationID: context.generationID,
                status: .failed,
                errorMessage: "old"
            )
            try await context.jobStore.enqueue(oldJob)
            try await context.stateStore.save(
                .needsManualRetry(
                    jobID: oldJob.id,
                    localeIdentifier: "de-DE",
                    reason: "Local failure"
                ),
                for: context.meetingID
            )

            let newRequest = try #require(try await context.reconciler.requestManualRetry(
                meetingID: context.meetingID,
                expectedImportGenerationID: context.generationID,
                localeIdentifier: "de-DE",
                modelsReady: true
            ))

            #expect(newRequest.id != MeetingTransferRequestID(rawValue: oldJob.id.rawValue))
            #expect(newRequest.jobID != oldJob.id)
            #expect(Set(try await context.jobStore.list().map(\.id))
                == [oldJob.id, newRequest.jobID])
            #expect(try await context.stateStore.load(context.meetingID) == .jobEnqueued(
                jobID: newRequest.jobID,
                localeIdentifier: "de-DE"
            ))
        }
    }

    @Test("manual retry cannot cross a trash and same-ID generation replacement")
    func manualRetryRejectsGenerationABA() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            try await context.stateStore.save(.importedOnly, for: context.meetingID)
            let pause = ReconcilerPause()
            let staleRetry = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: MeetingTransferStateStore(layout: context.library.layout),
                jobStore: try JobStore(layout: context.library.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .beforeManualRetryTransaction(
                        context.meetingID
                    ) else { return }
                    pause.arriveAndWait()
                }
            )
            let attempt = Task {
                try await staleRetry.requestManualRetry(
                    meetingID: context.meetingID,
                    expectedImportGenerationID: context.generationID,
                    localeIdentifier: "de-DE",
                    modelsReady: true
                )
            }
            try await eventually { pause.hasArrived }

            _ = try await context.library.trashMeeting(context.meetingID)
            let replacementGeneration = MeetingTransferGenerationID()
            let replacementReceipt = MeetingTransferReceipt(
                sourceMeetingID: context.meetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "a", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 90),
                sourceAppVersion: nil,
                includedCapabilities: [.notes],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: replacementGeneration
            )
            _ = try await context.library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(
                    id: context.meetingID,
                    title: "Replacement without audio",
                    status: .ready,
                    metadata: MeetingMetadata(transferReceipt: replacementReceipt)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            ))

            pause.release()
            await #expect(
                throws: ImportedMeetingProcessingReconcilerError.importGenerationConflict(
                    context.meetingID
                )
            ) {
                try await attempt.value
            }
            #expect(try await context.jobStore.list().isEmpty)
            #expect(try await context.stateStore.load(context.meetingID) == .importedOnly)
            #expect(try await context.library.listMediaAssets(
                meetingID: context.meetingID
            ).isEmpty)
            #expect(try await context.library.loadMeeting(context.meetingID)
                .metadata?.transferReceipt?.importGenerationID == replacementGeneration)
        }
    }

    @Test("two concurrent manual retries create exactly one new request and job")
    func concurrentManualRetriesUseOneCASWinner() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let oldJob = Job(
                kind: .finalASR,
                meetingID: context.meetingID,
                localeIdentifier: "de-DE",
                importGenerationID: context.generationID,
                status: .failed,
                errorMessage: "old"
            )
            try await context.jobStore.enqueue(oldJob)
            let initial: ImportedMeetingProcessingState = .needsManualRetry(
                jobID: oldJob.id,
                localeIdentifier: "de-DE",
                reason: "Local failure"
            )
            try await context.stateStore.save(initial, for: context.meetingID)
            let barrier = JobEnsureRaceBarrier(expectedArrivals: 2)
            let first = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: MeetingTransferStateStore(layout: context.library.layout),
                jobStore: try JobStore(layout: context.library.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .beforeManualRetryTransaction(
                        context.meetingID
                    ) else { return }
                    barrier.arriveAndWait()
                }
            )
            let second = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: MeetingTransferStateStore(layout: context.library.layout),
                jobStore: try JobStore(layout: context.library.layout),
                checkpoint: { checkpoint in
                    guard checkpoint == .beforeManualRetryTransaction(
                        context.meetingID
                    ) else { return }
                    barrier.arriveAndWait()
                }
            )

            async let firstAttempt = manualRetryAttempt(
                first,
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            async let secondAttempt = manualRetryAttempt(
                second,
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            let attempts = await [firstAttempt, secondAttempt]

            #expect(attempts.filter {
                if case .created = $0 { return true }
                return false
            }.count == 1)
            #expect(attempts.filter { $0 == .notAllowed }.count == 1)
            let jobs = try await context.jobStore.list()
            #expect(jobs.count == 2)
            #expect(jobs.filter { $0.id != oldJob.id }.count == 1)
            guard case .jobEnqueued(let jobID, let locale) = try await context.stateStore.load(
                context.meetingID
            ) else {
                Issue.record("expected one persisted retry job")
                return
            }
            #expect(jobID == jobs.first { $0.id != oldJob.id }?.id)
            #expect(locale == "de-DE")
        }
    }

    @Test("manual retry with a missing model records the locale but creates no job")
    func manualRetryAwaitsMissingModel() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            try await context.stateStore.save(
                .awaitingModel(localeIdentifier: "de-DE"),
                for: context.meetingID
            )

            let request = try await context.reconciler.requestManualRetry(
                meetingID: context.meetingID,
                expectedImportGenerationID: context.generationID,
                localeIdentifier: "de-DE",
                modelsReady: false
            )

            #expect(request == nil)
            #expect(try await context.jobStore.list().isEmpty)
            #expect(try await context.stateStore.load(context.meetingID)
                == .awaitingModel(localeIdentifier: "de-DE"))
        }
    }

    @Test("manual retry rejects an imported meeting without validated local audio")
    func manualRetryRequiresValidatedLocalAudio() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root, includeAudio: false)
            try await context.stateStore.save(.importedOnly, for: context.meetingID)

            await #expect(
                throws: ImportedMeetingProcessingReconcilerError.noAudioForProcessing(
                    context.meetingID
                )
            ) {
                try await context.reconciler.requestManualRetry(
                    meetingID: context.meetingID,
                    expectedImportGenerationID: context.generationID,
                    localeIdentifier: "de-DE",
                    modelsReady: true
                )
            }

            #expect(try await context.jobStore.list().isEmpty)
            #expect(try await context.stateStore.load(context.meetingID) == .importedOnly)
            #expect(try await context.library.loadMeeting(context.meetingID).status == .ready)
        }
    }

    @Test("pipeline startup reconciles persisted imports after job recovery and before consumption")
    func startupReconcilesPersistedRequest() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )

            let runtime = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "en-US")
            )
            try await runtime.coordinator.waitUntilIdle()

            let jobs = try await runtime.jobStore.list()
            #expect(jobs.map(\.id) == [request.jobID])
            #expect(jobs[0].localeIdentifier == "de-DE")
            #expect(jobs[0].status == .failed)
            #expect(try await MeetingTransferStateStore(layout: runtime.library.layout)
                .load(context.meetingID) == .needsManualRetry(
                    jobID: request.jobID,
                    localeIdentifier: "de-DE",
                    reason: "Processing failed."
                ))
            await runtime.coordinator.stop()
        }
    }

    @Test("pipeline startup rejects transfer state whose meeting metadata is missing")
    func startupRejectsTransferStateWithoutMeetingMetadata() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )
            let meetingURL = context.library.layout.meetingMetadata(context.meetingID)
            let stateURL = context.library.layout.transferState(context.meetingID)
            let stateBeforeStartup = try Data(contentsOf: stateURL)
            try FileManager.default.removeItem(at: meetingURL)

            do {
                let runtime = try await startPipeline(
                    at: root,
                    providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                    diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                    locale: Locale(identifier: "en-US")
                )
                await runtime.coordinator.stop()
                Issue.record("expected missing meeting metadata to block startup")
            } catch let error as LibraryError {
                guard case .meetingNotFound(let meetingID) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(meetingID == context.meetingID)
            }

            #expect(!FileManager.default.fileExists(atPath: meetingURL.path))
            #expect(try Data(contentsOf: stateURL) == stateBeforeStartup)
            #expect(try await context.jobStore.list().isEmpty)
        }
    }

    @Test("pipeline startup isolates a missing receipt and reconciles a healthy import")
    func startupIsolatesMissingReceipt() async throws {
        try await withTemporaryDirectory { root in
            let broken = try await makeReconcilerContext(at: root)
            let healthy = try await makeReconcilerContext(at: root)
            let brokenRequest = makeProcessingRequest(
                meetingID: broken.meetingID,
                generationID: broken.generationID
            )
            let healthyRequest = makeProcessingRequest(
                meetingID: healthy.meetingID,
                generationID: healthy.generationID
            )
            try await broken.stateStore.save(
                .processingRequested(brokenRequest),
                for: broken.meetingID
            )
            try await healthy.stateStore.save(
                .processingRequested(healthyRequest),
                for: healthy.meetingID
            )
            let brokenMeeting = try await broken.library.loadMeeting(broken.meetingID)
            let meetingWithoutReceipt = Meeting(
                schemaVersion: brokenMeeting.schemaVersion,
                id: brokenMeeting.id,
                title: brokenMeeting.title,
                createdAt: brokenMeeting.createdAt,
                status: brokenMeeting.status,
                participantIDs: brokenMeeting.participantIDs,
                additionalParticipantIDs: brokenMeeting.additionalParticipantIDs,
                folderID: brokenMeeting.folderID,
                metadata: nil,
                sourceLocale: brokenMeeting.sourceLocale
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(
                encoder.encode(meetingWithoutReceipt),
                to: broken.library.layout.meetingMetadata(broken.meetingID)
            )
            let brokenStateURL = broken.library.layout.transferState(broken.meetingID)
            let brokenStateBeforeStartup = try Data(contentsOf: brokenStateURL)

            let runtime = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "en-US")
            )
            try await runtime.coordinator.waitUntilIdle()

            #expect(try await runtime.library.listMeetings().count == 2)
            #expect(try await runtime.jobStore.list().map(\.id) == [healthyRequest.jobID])
            #expect(runtime.startupWarnings == [
                .importedMeetingProcessing(
                    meetingID: broken.meetingID,
                    issue: .invalidTransferState
                ),
            ])
            #expect(try Data(contentsOf: brokenStateURL) == brokenStateBeforeStartup)
            #expect(try await runtime.library.loadMeeting(broken.meetingID)
                .metadata?.transferReceipt == nil)
            await runtime.coordinator.stop()
        }
    }

    @Test("pipeline startup quarantines a malformed transfer state and continues")
    func startupQuarantinesMalformedTransferState() async throws {
        try await withTemporaryDirectory { root in
            let broken = try await makeReconcilerContext(at: root)
            let healthy = try await makeReconcilerContext(at: root)
            let healthyRequest = makeProcessingRequest(
                meetingID: healthy.meetingID,
                generationID: healthy.generationID
            )
            try await healthy.stateStore.save(
                .processingRequested(healthyRequest),
                for: healthy.meetingID
            )
            let malformed = Data("{".utf8)
            let brokenStateURL = broken.library.layout.transferState(broken.meetingID)
            try AtomicFile.write(malformed, to: brokenStateURL)

            let runtime = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "en-US")
            )
            try await runtime.coordinator.waitUntilIdle()

            #expect(try await runtime.jobStore.list().map(\.id) == [healthyRequest.jobID])
            #expect(runtime.startupWarnings == [
                .importedMeetingProcessing(
                    meetingID: broken.meetingID,
                    issue: .invalidTransferState
                ),
            ])
            #expect(!FileManager.default.fileExists(atPath: brokenStateURL.path))
            let quarantined = try FileManager.default.contentsOfDirectory(
                at: broken.library.layout.meetingDirectory(broken.meetingID),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("transfer-state.json.corrupt-") }
            #expect(quarantined.count == 1)
            let quarantinedState = try #require(quarantined.first)
            #expect(try Data(contentsOf: quarantinedState) == malformed)
            await runtime.coordinator.stop()
        }
    }

    @Test("pipeline startup reports a job identity conflict and continues")
    func startupIsolatesJobIdentityConflict() async throws {
        try await withTemporaryDirectory { root in
            let broken = try await makeReconcilerContext(at: root)
            let healthy = try await makeReconcilerContext(at: root)
            let brokenRequest = makeProcessingRequest(
                meetingID: broken.meetingID,
                generationID: broken.generationID
            )
            let healthyRequest = makeProcessingRequest(
                meetingID: healthy.meetingID,
                generationID: healthy.generationID
            )
            try await broken.stateStore.save(
                .processingRequested(brokenRequest),
                for: broken.meetingID
            )
            try await healthy.stateStore.save(
                .processingRequested(healthyRequest),
                for: healthy.meetingID
            )
            let conflictingJob = Job(
                id: brokenRequest.jobID,
                kind: .finalASR,
                meetingID: healthy.meetingID,
                localeIdentifier: brokenRequest.localeIdentifier,
                importGenerationID: brokenRequest.importGenerationID,
                status: .finished,
                createdAt: brokenRequest.createdAt
            )
            try await broken.jobStore.enqueue(conflictingJob)
            let brokenStateURL = broken.library.layout.transferState(broken.meetingID)
            let brokenStateBeforeStartup = try Data(contentsOf: brokenStateURL)

            let runtime = try await startPipeline(
                at: root,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "en-US")
            )
            try await runtime.coordinator.waitUntilIdle()

            #expect(Set(try await runtime.jobStore.list().map(\.id))
                == [brokenRequest.jobID, healthyRequest.jobID])
            #expect(runtime.startupWarnings == [
                .importedMeetingProcessing(
                    meetingID: broken.meetingID,
                    issue: .jobIdentityConflict
                ),
            ])
            #expect(try Data(contentsOf: brokenStateURL) == brokenStateBeforeStartup)
            await runtime.coordinator.stop()
        }
    }

    @Test("pipeline startup does not collect an unrelated reconciliation error")
    func startupDoesNotSwallowUnrelatedErrors() async throws {
        try await withTemporaryDirectory { root in
            let context = try await makeReconcilerContext(at: root)
            let request = makeProcessingRequest(
                meetingID: context.meetingID,
                generationID: context.generationID
            )
            try await context.stateStore.save(
                .processingRequested(request),
                for: context.meetingID
            )
            let reconciler = ImportedMeetingProcessingReconciler(
                library: context.library,
                stateStore: context.stateStore,
                jobStore: context.jobStore,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterCandidateStateReadBeforeTransaction else { return }
                    throw ReconcilerTestError.crash
                }
            )

            await #expect(throws: ReconcilerTestError.crash) {
                try await reconciler.reconcileAtPipelineStartup()
            }
            #expect(try await context.jobStore.list().isEmpty)
            #expect(try await context.stateStore.load(context.meetingID)
                == .processingRequested(request))
        }
    }
}

private struct ReconcilerContext: Sendable {
    let library: Library
    let meetingID: MeetingID
    let generationID: MeetingTransferGenerationID
    let stateStore: MeetingTransferStateStore
    let jobStore: JobStore
    let reconciler: ImportedMeetingProcessingReconciler
}

private enum ReconcilerTestError: Error {
    case crash
}

private enum EnsureAttempt: Equatable, Sendable {
    case inserted
    case alreadyMatching
    case identityConflict
    case unexpected
}

private enum ManualRetryAttempt: Equatable, Sendable {
    case created
    case notAllowed
    case unexpected
}

private final class JobEnsureRaceBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedArrivals: Int
    private var arrivals = 0

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    func arriveAndWait() {
        condition.lock()
        arrivals += 1
        if arrivals == expectedArrivals {
            condition.broadcast()
        } else {
            while arrivals < expectedArrivals {
                condition.wait()
            }
        }
        condition.unlock()
    }
}

private final class ReconcilerPause: @unchecked Sendable {
    private let arrived = Mutex(false)
    private let resume = DispatchSemaphore(value: 0)

    var hasArrived: Bool { arrived.withLock { $0 } }

    func arriveAndWait() {
        arrived.withLock { $0 = true }
        resume.wait()
    }

    func release() {
        resume.signal()
    }
}

private final class ReconcilerGroupPause: @unchecked Sendable {
    private struct State: Sendable {
        var arrivals = 0
    }

    private let expectedArrivals: Int
    private let state = Mutex(State())
    private let resume = DispatchSemaphore(value: 0)

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    var allArrived: Bool {
        state.withLock { $0.arrivals == expectedArrivals }
    }

    func arriveAndWait() {
        state.withLock { $0.arrivals += 1 }
        resume.wait()
    }

    func release() {
        for _ in 0..<expectedArrivals {
            resume.signal()
        }
    }
}

private func ensureAttempt(_ job: Job, store: JobStore) async -> EnsureAttempt {
    do {
        switch try await store.ensureEnqueued(job) {
        case .inserted: return .inserted
        case .alreadyMatching: return .alreadyMatching
        }
    } catch let error as LibraryError {
        if case .jobIdentityConflict = error { return .identityConflict }
        return .unexpected
    } catch {
        return .unexpected
    }
}

private func manualRetryAttempt(
    _ reconciler: ImportedMeetingProcessingReconciler,
    meetingID: MeetingID,
    generationID: MeetingTransferGenerationID
) async -> ManualRetryAttempt {
    do {
        let request = try await reconciler.requestManualRetry(
            meetingID: meetingID,
            expectedImportGenerationID: generationID,
            localeIdentifier: "de-DE",
            modelsReady: true
        )
        return request == nil ? .unexpected : .created
    } catch ImportedMeetingProcessingReconcilerError.manualRetryNotAllowed {
        return .notAllowed
    } catch {
        return .unexpected
    }
}

private func makeReconcilerContext(
    at root: URL,
    includeAudio: Bool = true
) async throws -> ReconcilerContext {
    let library = try Library.open(at: root)
    let meetingID = MeetingID()
    let generationID = MeetingTransferGenerationID()
    let receipt = MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        sourcePackageContentDigest: String(repeating: "a", count: 64),
        importedAt: Date(timeIntervalSinceReferenceDate: 1),
        sourceAppVersion: nil,
        includedCapabilities: [.notes],
        sourceLocaleIdentifier: "de-DE",
        sourceLocaleOrigin: .explicit,
        importGenerationID: generationID
    )
    let meeting = Meeting(
        id: meetingID,
        title: "Imported",
        status: .ready,
        metadata: MeetingMetadata(transferReceipt: receipt)
    )
    let media: [PreparedMediaImport]
    if includeAudio {
        let source = root.appending(path: "reconciler-audio.caf")
        try makePipelineTestCAF(at: source)
        let inspection = try MeetingTransferAudioInspector().inspectCAFSource(at: source)
        let asset = MediaAsset(
            meetingID: meetingID,
            kind: .micTrack,
            sampleRate: inspection.sampleRate,
            duration: inspection.duration,
            provenanceKey: "transfer:\(meetingID):track-1:\(String(repeating: "b", count: 64))",
            fileName: "audio.caf"
        )
        media = [.init(asset: asset, sourceURL: source)]
    } else {
        media = []
    }
    _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: meeting,
        media: media,
        revision: nil,
        transferState: .importedOnly,
        notes: [.init(fileName: "user-notes.md", data: Data("note".utf8))]
    ))
    let stateStore = MeetingTransferStateStore(layout: library.layout)
    let jobStore = try JobStore(layout: library.layout)
    return ReconcilerContext(
        library: library,
        meetingID: meetingID,
        generationID: generationID,
        stateStore: stateStore,
        jobStore: jobStore,
        reconciler: ImportedMeetingProcessingReconciler(
            library: library,
            stateStore: stateStore,
            jobStore: jobStore
        )
    )
}

private func makeProcessingRequest(
    meetingID: MeetingID,
    generationID: MeetingTransferGenerationID
) -> ImportedProcessingRequest {
    ImportedProcessingRequest(
        id: MeetingTransferRequestID(),
        jobID: JobID(),
        meetingID: meetingID,
        localeIdentifier: "de-DE",
        createdAt: Date(timeIntervalSinceReferenceDate: 42),
        importGenerationID: generationID
    )
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
