import Foundation
import StenoDomain
import StenoExchange
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Meeting transfer import presentation")
struct MeetingTransferImportPresentationTests {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test("Startup reconciliation warning is generic and nonblocking")
    func startupWarningDoesNotExposeMeetingDetails() throws {
        let warning = PipelineStartupWarning.importedMeetingProcessing(
            meetingID: meetingID,
            issue: .jobIdentityConflict
        )

        let message = try #require(AppModel.pipelineStartupWarningMessage(for: [warning]))

        #expect(message == "One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available.")
        #expect(!message.contains(meetingID.description))
        #expect(AppModel.pipelineStartupWarningMessage(for: []) == nil)
    }

    @Test("Preview keeps safe metadata and makes cleartext boundaries explicit")
    func previewContentAndWarnings() {
        let presentation = makePresentation(
            capabilities: [.notes, .transcript, .audio],
            speakerLabels: ["Alex", "Sam"],
            audioTracks: [
                .init(label: "Microphone", byteCount: 1_500_000),
                .init(label: "System audio", byteCount: 2_500_000),
            ]
        )

        #expect(presentation.title == "Budget review")
        #expect(presentation.sourceMeetingID == meetingID)
        #expect(presentation.technicalOriginID == "11111111")
        #expect(presentation.capabilityLabels == ["Notes", "Transcript", "Audio"])
        #expect(presentation.visibleSpeakerLabels == ["Alex", "Sam"])
        #expect(presentation.containsPersonalSpeakerLabels)
        #expect(presentation.audioTrackCount == 2)
        #expect(presentation.totalAudioBytes == 4_000_000)
        #expect(presentation.containsRawRecording)
        #expect(presentation.cleartextWarning.contains("unencrypted"))
        #expect(presentation.downloadsWarning.contains("Downloads"))
        #expect(presentation.downloadsWarning.contains("search indexing"))
        #expect(presentation.downloadsWarning.contains("backup"))
    }

    @Test("Conflict has no mutating action")
    func conflictBlocksImport() {
        #expect(
            MeetingTransferImportPresentation.actions(
                for: .conflict(meetingID),
                hasAudio: true
            ) == [.close]
        )
    }

    @Test("Already present opens the existing meeting without importing")
    func alreadyPresentIsVisibleNoOp() {
        #expect(
            MeetingTransferImportPresentation.actions(
                for: .alreadyPresent(meetingID),
                hasAudio: true
            ) == [.openExisting, .close]
        )
    }

    @Test("Text-only packages have exactly one mutating action")
    func textOnlyImportsWithoutProcessing() {
        #expect(
            MeetingTransferImportPresentation.actions(for: .new, hasAudio: false)
                == [.importOnly, .close]
        )
    }

    @Test("Audio packages offer import only and import with processing")
    func audioOffersBothLocalChoices() {
        #expect(
            MeetingTransferImportPresentation.actions(for: .new, hasAudio: true)
                == [.importOnly, .importAndProcess, .close]
        )
    }

    @Test("Every processing choice requires local language confirmation")
    func allLanguageOriginsNeedLocalConfirmation() {
        #expect(MeetingTransferImportPresentation.requiresLanguageConfirmation(.explicit))
        #expect(MeetingTransferImportPresentation.requiresLanguageConfirmation(.estimated))
        #expect(MeetingTransferImportPresentation.requiresLanguageConfirmation(.absent))
    }

    @Test("Source locale may be preselected but absence never guesses")
    func localePreselection() {
        #expect(
            makePresentation(localeIdentifier: "de-DE", localeOrigin: .explicit)
                .preselectedLocaleIdentifier == "de-DE"
        )
        #expect(
            makePresentation(localeIdentifier: "fr-FR", localeOrigin: .estimated)
                .preselectedLocaleIdentifier == "fr-FR"
        )
        #expect(
            makePresentation(localeIdentifier: nil, localeOrigin: .absent)
                .preselectedLocaleIdentifier == nil
        )
    }

    @Test("Missing model remains an import outcome and never promises a job")
    func missingModelOutcome() {
        #expect(
            MeetingTransferImportPresentation.processingOutcome(modelsReady: false)
                == .importsAwaitingModel
        )
        #expect(
            MeetingTransferImportPresentation.processingOutcome(modelsReady: true)
                == .enqueuesPinnedProcessing
        )
    }

    @Test("Transfer detail never presents pending recovery as success")
    func pendingRecoveryIsNotSuccess() {
        let receipt = makeReceipt()

        #expect(
            MeetingTransferDetailPresentation.make(
                receipt: receipt,
                state: .processingRequested(makeRequest()),
                hasAudio: true,
                requiresFreshImportRetry: true
            ).processingStatus == .recoveryRequired
        )
    }

    @Test("Transfer detail maps every persisted processing state explicitly")
    func detailStateMapping() {
        let receipt = makeReceipt()
        #expect(detail(receipt, .importedOnly).processingStatus == .ready)
        #expect(detail(receipt, .awaitingLanguageConfirmation).processingStatus == .confirmLanguage)
        #expect(
            detail(receipt, .awaitingModel(localeIdentifier: "de-DE")).processingStatus
                == .modelMissing(localeIdentifier: "de-DE")
        )
        #expect(detail(receipt, .processingRequested(makeRequest())).processingStatus == .processing)
        let queued = makeJob(receipt: receipt, status: .queued)
        #expect(detail(
            receipt,
            .jobEnqueued(jobID: queued.id, localeIdentifier: "de-DE"),
            job: queued
        ).processingStatus == .processing)
        #expect(
            detail(
                receipt,
                .needsManualRetry(
                    jobID: JobID(),
                    localeIdentifier: "de-DE",
                    reason: "model disappeared"
                )
            ).processingStatus == .failed(
                localeIdentifier: "de-DE",
                reason: "model disappeared"
            )
        )
    }

    @Test("Enqueued import status follows the exact persisted job through every terminal state")
    func enqueuedJobStatusMapping() {
        let receipt = makeReceipt()
        let queued = makeJob(receipt: receipt, status: .queued)
        let running = makeJob(receipt: receipt, status: .running)
        let finished = makeJob(receipt: receipt, status: .finished)
        let failed = makeJob(
            receipt: receipt,
            status: .failed,
            errorMessage: "Provider failed locally."
        )
        let cancelled = makeJob(receipt: receipt, status: .cancelled)

        #expect(jobDetail(receipt, queued).processingStatus == .processing)
        #expect(jobDetail(receipt, running).processingStatus == .processing)
        #expect(jobDetail(receipt, finished).processingStatus == .completed)
        #expect(jobDetail(receipt, finished).actions.isEmpty)
        #expect(jobDetail(receipt, failed).processingStatus == .failed(
            localeIdentifier: "de-DE",
            reason: "Provider failed locally."
        ))
        #expect(jobDetail(receipt, failed).actions == [.retry])
        #expect(jobDetail(receipt, cancelled).processingStatus == .failed(
            localeIdentifier: "de-DE",
            reason: "Processing was cancelled."
        ))
        #expect(jobDetail(receipt, cancelled).actions == [.retry])
    }

    @Test("Mismatched job generation is visible but never retryable")
    func mismatchedJobGenerationBlocksRetry() {
        let receipt = makeReceipt()
        let mismatched = Job(
            kind: .finalASR,
            meetingID: meetingID,
            localeIdentifier: "de-DE",
            importGenerationID: MeetingTransferGenerationID(),
            status: .failed,
            errorMessage: "wrong generation"
        )
        let presentation = jobDetail(receipt, mismatched)

        guard case .failed(_, let reason) = presentation.processingStatus else {
            Issue.record("expected a visible inconsistent processing state")
            return
        }
        #expect(reason.contains("does not match"))
        #expect(presentation.actions.isEmpty)
    }

    @Test("Text-only awaiting-language receipt is ready without an impossible action")
    func textOnlyAwaitingLanguageIsReady() {
        let presentation = MeetingTransferDetailPresentation.make(
            receipt: makeReceipt(),
            state: .awaitingLanguageConfirmation,
            hasAudio: false,
            requiresFreshImportRetry: false
        )

        #expect(presentation.processingStatus == .ready)
        #expect(presentation.actions.isEmpty)
    }

    @Test("Detail actions follow persisted state and never offer processing without audio")
    func detailActionPolicy() {
        let receipt = makeReceipt()
        #expect(detail(receipt, .importedOnly).actions == [.process])
        #expect(detail(receipt, .awaitingLanguageConfirmation).actions == [.confirmLanguage])
        #expect(
            detail(receipt, .awaitingModel(localeIdentifier: "de-DE")).actions
                == [.installModelAndProcess]
        )
        #expect(detail(receipt, .processingRequested(makeRequest())).actions.isEmpty)
        #expect(
            detail(
                receipt,
                .needsManualRetry(
                    jobID: JobID(),
                    localeIdentifier: "de-DE",
                    reason: "failed"
                )
            ).actions == [.retry]
        )
        #expect(
            MeetingTransferDetailPresentation.make(
                receipt: receipt,
                state: .importedOnly,
                hasAudio: false,
                requiresFreshImportRetry: false
            ).actions.isEmpty
        )
        #expect(
            MeetingTransferDetailPresentation.make(
                receipt: receipt,
                state: .awaitingLanguageConfirmation,
                hasAudio: true,
                requiresFreshImportRetry: true
            ).actions.isEmpty
        )
    }

    private func makePresentation(
        capabilities: Set<MeetingTransferCapability> = [.notes],
        speakerLabels: [String] = [],
        audioTracks: [MeetingTransferImportPresentation.AudioTrack] = [],
        localeIdentifier: String? = "de-DE",
        localeOrigin: MeetingTransferLocaleOrigin = .explicit,
        disposition: MeetingTransferImportDisposition = .new
    ) -> MeetingTransferImportPresentation {
        MeetingTransferImportPresentation(
            sessionID: sessionID,
            sourceMeetingID: meetingID,
            title: "Budget review",
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456),
            capabilities: capabilities,
            visibleSpeakerLabels: speakerLabels,
            audioTracks: audioTracks,
            localeIdentifier: localeIdentifier,
            localeOrigin: localeOrigin,
            disposition: disposition
        )
    }

    private func makeReceipt() -> MeetingTransferReceipt {
        MeetingTransferReceipt(
            sourceMeetingID: meetingID,
            sourceRevisionID: nil,
            sourcePackageContentDigest: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            sourceAppVersion: "1.0",
            includedCapabilities: [.audio],
            sourceLocaleIdentifier: "de-DE",
            sourceLocaleOrigin: .explicit,
            importGenerationID: MeetingTransferGenerationID()
        )
    }

    private func makeRequest() -> ImportedProcessingRequest {
        ImportedProcessingRequest(
            id: MeetingTransferRequestID(),
            jobID: JobID(),
            meetingID: meetingID,
            localeIdentifier: "de-DE",
            createdAt: Date(),
            importGenerationID: MeetingTransferGenerationID()
        )
    }

    private func detail(
        _ receipt: MeetingTransferReceipt,
        _ state: ImportedMeetingProcessingState,
        job: Job? = nil
    ) -> MeetingTransferDetailPresentation {
        MeetingTransferDetailPresentation.make(
            receipt: receipt,
            state: state,
            hasAudio: true,
            requiresFreshImportRetry: false,
            job: job
        )
    }

    private func jobDetail(
        _ receipt: MeetingTransferReceipt,
        _ job: Job
    ) -> MeetingTransferDetailPresentation {
        detail(
            receipt,
            .jobEnqueued(jobID: job.id, localeIdentifier: "de-DE"),
            job: job
        )
    }

    private func makeJob(
        receipt: MeetingTransferReceipt,
        status: Job.Status,
        errorMessage: String? = nil
    ) -> Job {
        Job(
            kind: .finalASR,
            meetingID: meetingID,
            localeIdentifier: "de-DE",
            importGenerationID: receipt.importGenerationID,
            status: status,
            errorMessage: errorMessage
        )
    }
}

@MainActor
@Suite("Meeting transfer detail actions")
struct MeetingTransferDetailActionTests {
    @Test("Manual processing always carries the displayed import generation")
    func retryIsGenerationSafe() async {
        let harness = MeetingTransferDetailHarness()
        let model = AppModel(meetingTransferDetailClient: harness.client())

        let succeeded = await model.retryImportedMeetingProcessing(
            meetingID: harness.meetingID,
            localeIdentifier: "de-DE",
            modelsReady: true
        )

        #expect(succeeded)
        #expect(await harness.retryCount == 1)
        #expect(await harness.receivedGeneration == harness.generationID)
        #expect(await harness.receivedLocale == "de-DE")
        #expect(await harness.receivedModelsReady == true)
    }

    @Test("A receipt without a generation cannot start processing")
    func missingGenerationDoesNotRetry() async {
        let harness = MeetingTransferDetailHarness(includeGeneration: false)
        let model = AppModel(meetingTransferDetailClient: harness.client())

        let succeeded = await model.retryImportedMeetingProcessing(
            meetingID: harness.meetingID,
            localeIdentifier: "de-DE",
            modelsReady: true
        )

        #expect(!succeeded)
        #expect(await harness.retryCount == 0)
    }

    @Test("Manual processing restarts observation for a combined import until failure is visible")
    func manualProcessingRestartsObservationWithExistingTranscript() {
        let meetingID = MeetingID()
        var observation = MeetingDetailObservationState()
        let initialKey = observation.key(for: meetingID)

        #expect(!MeetingDetailObservationPolicy.shouldContinue(
            hasRevision: true,
            jobs: [],
            transferStatus: .ready
        ))

        observation.restartAfterManualProcessingRequest()

        #expect(observation.key(for: meetingID) != initialKey)
        #expect(MeetingDetailObservationPolicy.shouldContinue(
            hasRevision: true,
            jobs: [],
            transferStatus: .processing
        ))
        #expect(!MeetingDetailObservationPolicy.shouldContinue(
            hasRevision: true,
            jobs: [Job(
                kind: .diarization,
                meetingID: meetingID,
                status: .failed,
                errorMessage: "Diarization failed."
            )],
            transferStatus: .failed(
                localeIdentifier: "de-DE",
                reason: "Processing failed."
            )
        ))
        #expect(!MeetingDetailObservationPolicy.shouldContinue(
            hasRevision: false,
            jobs: [],
            transferStatus: .failed(
                localeIdentifier: "de-DE",
                reason: "Processing failed before a transcript existed."
            )
        ))
    }
}

@MainActor
@Suite("Meeting transfer import lifecycle")
struct MeetingTransferImportLifecycleTests {
    @Test("Cold-start URL queue is bounded and latest request wins when the service becomes ready")
    func coldStartKeepsOnlyLatestURLUntilClientIsReady() async throws {
        let harness = ImportLifecycleHarness()
        let security = SecurityScopeRecorder()
        let model = AppModel(meetingTransferSecurityScope: security.client)
        let firstURL = URL(fileURLWithPath: "/external/first.stenomeeting")
        let secondURL = URL(fileURLWithPath: "/external/second.stenomeeting")

        model.previewMeetingPackage(at: firstURL)
        model.previewMeetingPackage(at: secondURL)

        #expect(await harness.prepareCount == 0)
        #expect(security.starts.isEmpty)
        #expect(security.stops.isEmpty)

        model.meetingTransferClient = harness.client()

        #expect(await eventually { await harness.prepareCount == 1 })
        #expect(model.pendingMeetingTransferURL == nil)
        #expect(await harness.preparedURLs == [secondURL])
        await harness.resumePrepare(at: 0, title: "Second")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "Second" })
        #expect(security.starts == [secondURL])
        #expect(security.stops == [secondURL])
        #expect(!containsURL(model.meetingTransferImportState as Any))
    }

    @Test("Security-scoped access ends after the private snapshot is prepared")
    func securityScopeEndsAfterPrepare() async throws {
        let harness = ImportLifecycleHarness()
        let security = SecurityScopeRecorder()
        let model = AppModel(
            meetingTransferClient: harness.client(),
            meetingTransferSecurityScope: security.client
        )
        let url = URL(fileURLWithPath: "/external/first.stenomeeting")

        model.previewMeetingPackage(at: url)
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "First")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "First" })

        #expect(security.starts == [url])
        #expect(security.stops == [url])
        #expect(model.pendingMeetingTransferURL == nil)
        #expect(!containsURL(model.meetingTransferImportState as Any))
    }

    @Test("A second open discards the first session and ignores its stale result")
    func secondOpenReplacesFirstDialog() async throws {
        let harness = ImportLifecycleHarness()
        let security = SecurityScopeRecorder()
        let model = AppModel(
            meetingTransferClient: harness.client(),
            meetingTransferSecurityScope: security.client
        )
        let firstURL = URL(fileURLWithPath: "/external/first.stenomeeting")
        let secondURL = URL(fileURLWithPath: "/external/second.stenomeeting")

        model.previewMeetingPackage(at: firstURL)
        #expect(await eventually { await harness.prepareCount == 1 })
        model.previewMeetingPackage(at: secondURL)
        await harness.resumePrepare(at: 0, title: "First")

        #expect(await eventually { await harness.prepareCount == 2 })
        await harness.resumePrepare(at: 1, title: "Second")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "Second" })

        #expect(await harness.discardedSessionIDs.count == 1)
        #expect(security.starts == [firstURL, secondURL])
        #expect(security.stops == [firstURL, secondURL])
    }

    @Test("Closing during prepare cancels hashing, balances access and discards a late session")
    func closeDuringPrepare() async throws {
        let harness = ImportLifecycleHarness()
        let security = SecurityScopeRecorder()
        let model = AppModel(
            meetingTransferClient: harness.client(),
            meetingTransferSecurityScope: security.client
        )
        let url = URL(fileURLWithPath: "/external/large.stenomeeting")

        model.previewMeetingPackage(at: url)
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.reportHashProgress(processedBytes: 40, totalBytes: 100)
        #expect(
            await eventually {
                model.meetingTransferImportState?.progress?.processedBytes == 40
            }
        )

        model.closeMeetingTransferImport()
        await harness.resumePrepare(at: 0, title: "Late")

        #expect(await eventually { model.meetingTransferImportState == nil })
        #expect(await harness.discardedSessionIDs.count == 1)
        #expect(security.starts == [url])
        #expect(security.stops == [url])
    }

    @Test("Closing during import cancels the operation and discards the prepared session")
    func closeDuringImport() async throws {
        let harness = ImportLifecycleHarness(importWaitsForCancellation: true)
        let model = AppModel(meetingTransferClient: harness.client())
        let url = URL(fileURLWithPath: "/external/audio.stenomeeting")

        model.previewMeetingPackage(at: url)
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "Audio")
        #expect(await eventually { model.meetingTransferImportState?.preview != nil })

        model.importMeetingPackage(choice: .importOnly)
        #expect(await eventually { await harness.importCount == 1 })
        model.closeMeetingTransferImport()

        #expect(await eventually { await harness.importWasCancelled })
        #expect(await eventually { model.meetingTransferImportState == nil })
        #expect(await harness.discardedSessionIDs.count == 1)
    }

    @Test("A commit that finishes after close remains visible before a queued successor starts")
    func completedCommitWinsOverCancellationAndSerializesSuccessor() async throws {
        let committedMeetingID = MeetingID()
        let harness = ImportLifecycleHarness(importWaitsForResume: true)
        let model = AppModel(meetingTransferClient: harness.client())
        let firstURL = URL(fileURLWithPath: "/external/first.stenomeeting")
        let secondURL = URL(fileURLWithPath: "/external/second.stenomeeting")

        model.previewMeetingPackage(at: firstURL)
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "First")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "First" })
        model.importMeetingPackage(choice: .importOnly)
        #expect(await eventually { await harness.importCount == 1 })

        model.closeMeetingTransferImport()
        model.previewMeetingPackage(at: secondURL)
        #expect(await harness.prepareCount == 1)

        await harness.resumeImport(with: .imported(committedMeetingID))

        #expect(
            await eventually {
                guard case .completed(.imported(committedMeetingID)) =
                        model.meetingTransferImportState else { return false }
                return true
            }
        )
        #expect(model.selectedMeetingID == nil)
        #expect(await harness.prepareCount == 1)
        #expect(await harness.discardedSessionIDs.isEmpty)

        model.closeMeetingTransferImport()

        #expect(await eventually { model.selectedMeetingID == committedMeetingID })
        #expect(await eventually { await harness.prepareCount == 2 })
        await harness.resumePrepare(at: 1, title: "Second")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "Second" })
    }

    @Test("Pending recovery after cancellation stays visible and blocks the queued successor")
    func pendingRecoveryWinsOverCancellation() async throws {
        let uncertainMeetingID = MeetingID()
        let harness = ImportLifecycleHarness(importWaitsForResume: true)
        let model = AppModel(meetingTransferClient: harness.client())

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/external/uncertain.stenomeeting")
        )
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "Uncertain")
        #expect(await eventually { model.meetingTransferImportState?.preview != nil })
        model.importMeetingPackage(choice: .importOnly)
        #expect(await eventually { await harness.importCount == 1 })

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/external/queued.stenomeeting")
        )
        await harness.resumeImport(with: .pendingRecovery(uncertainMeetingID))

        #expect(
            await eventually {
                model.meetingTransferImportState == .recoveryRequired(uncertainMeetingID)
            }
        )
        #expect(await harness.prepareCount == 1)

        model.closeMeetingTransferImport()
        #expect(await eventually { await harness.prepareCount == 2 })
    }

    @Test("Preparation cleanup failure keeps its session for a visible retry")
    func preparationCleanupCanRetry() async throws {
        let sessionID = UUID()
        let harness = ImportLifecycleHarness(
            prepareError: MeetingTransferImportError.preparationCleanupRequired(sessionID),
            discardFailures: 1
        )
        let model = AppModel(meetingTransferClient: harness.client())

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/external/broken.stenomeeting")
        )
        #expect(
            await eventually {
                model.meetingTransferImportState?.cleanupSessionID == sessionID
            }
        )

        model.retryMeetingTransferCleanup()
        #expect(await eventually { await harness.discardAttempts == 1 })
        #expect(model.meetingTransferImportState?.cleanupSessionID == sessionID)

        model.retryMeetingTransferCleanup()
        #expect(await eventually { model.meetingTransferImportState == nil })
        #expect(await harness.discardAttempts == 2)
    }

    @Test("Committed cleanup failure is not success until cleanup completes")
    func committedCleanupCanRetry() async throws {
        let sessionID = UUID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(
            importError: MeetingTransferImportError.cleanupRequired(
                sessionID: sessionID,
                committedResult: .imported(meetingID)
            )
        )
        let model = AppModel(meetingTransferClient: harness.client())

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/external/committed.stenomeeting")
        )
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "Committed")
        #expect(await eventually { model.meetingTransferImportState?.preview != nil })
        model.importMeetingPackage(choice: .importOnly)

        #expect(
            await eventually {
                model.meetingTransferImportState?.cleanupSessionID == sessionID
            }
        )
        #expect(model.selectedMeetingID == nil)

        model.retryMeetingTransferCleanup()
        #expect(await eventually { model.meetingTransferImportState == nil })
        #expect(model.selectedMeetingID == meetingID)
    }

    @Test("Cleanup retry finishes before a queued replacement can mutate import state")
    func cleanupRetrySerializesQueuedReplacement() async throws {
        let sessionID = UUID()
        let committedMeetingID = MeetingID()
        let harness = ImportLifecycleHarness(
            importError: MeetingTransferImportError.cleanupRequired(
                sessionID: sessionID,
                committedResult: .imported(committedMeetingID)
            ),
            discardWaitsForResume: true
        )
        let model = AppModel(meetingTransferClient: harness.client())
        let queuedURL = URL(fileURLWithPath: "/external/queued-after-cleanup.stenomeeting")

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/external/committed-cleanup.stenomeeting")
        )
        #expect(await eventually { await harness.prepareCount == 1 })
        await harness.resumePrepare(at: 0, title: "Committed")
        #expect(await eventually { model.meetingTransferImportState?.preview != nil })
        model.importMeetingPackage(choice: .importOnly)
        #expect(
            await eventually {
                model.meetingTransferImportState?.cleanupSessionID == sessionID
            }
        )

        model.previewMeetingPackage(at: queuedURL)
        model.retryMeetingTransferCleanup()
        #expect(await eventually { await harness.discardAttempts == 1 })
        #expect(await harness.prepareCount == 1)
        #expect(model.meetingTransferImportState?.cleanupSessionID == sessionID)

        await harness.resumeDiscard()

        #expect(await eventually { model.selectedMeetingID == committedMeetingID })
        #expect(await eventually { await harness.prepareCount == 2 })
        await harness.resumePrepare(at: 1, title: "Queued")
        #expect(await eventually { model.meetingTransferImportState?.preview?.title == "Queued" })
        #expect(await harness.preparedURLs.last == queuedURL)
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func containsURL(_ value: Any) -> Bool {
        if value is URL { return true }
        return Mirror(reflecting: value).children.contains {
            containsURL($0.value)
        }
    }
}

private actor ImportLifecycleHarness {
    struct PendingPrepare {
        let sessionID: UUID
        let progress: @Sendable (MeetingTransferProgress) -> Void
        let continuation: CheckedContinuation<MeetingTransferImportPresentation, Error>
    }

    private var pendingPrepares: [PendingPrepare] = []
    private var pendingImport: CheckedContinuation<MeetingTransferImportResult, Never>?
    private var pendingDiscard: CheckedContinuation<Void, Never>?
    private(set) var preparedURLs: [URL] = []
    private(set) var discardedSessionIDs: [UUID] = []
    private(set) var importCount = 0
    private(set) var importWasCancelled = false
    private(set) var discardAttempts = 0
    private let importWaitsForCancellation: Bool
    private let importWaitsForResume: Bool
    private let discardWaitsForResume: Bool
    private let prepareError: Error?
    private let importError: Error?
    private var discardFailures: Int

    var prepareCount: Int { pendingPrepares.count }

    init(
        importWaitsForCancellation: Bool = false,
        importWaitsForResume: Bool = false,
        prepareError: Error? = nil,
        importError: Error? = nil,
        discardFailures: Int = 0,
        discardWaitsForResume: Bool = false
    ) {
        self.importWaitsForCancellation = importWaitsForCancellation
        self.importWaitsForResume = importWaitsForResume
        self.discardWaitsForResume = discardWaitsForResume
        self.prepareError = prepareError
        self.importError = importError
        self.discardFailures = discardFailures
    }

    nonisolated func client() -> MeetingTransferImportClient {
        MeetingTransferImportClient(
            prepareImport: { [weak self] url, progress in
                guard let self else { throw CancellationError() }
                return try await self.prepare(url: url, progress: progress)
            },
            importPrepared: { [weak self] sessionID, choice, progress in
                guard let self else { throw CancellationError() }
                return try await self.runImport(
                    sessionID: sessionID,
                    choice: choice,
                    progress: progress
                )
            },
            discardPrepared: { [weak self] sessionID in
                guard let self else { throw CancellationError() }
                try await self.discard(sessionID)
            }
        )
    }

    private func prepare(
        url: URL,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void
    ) async throws -> MeetingTransferImportPresentation {
        if let prepareError { throw prepareError }
        preparedURLs.append(url)
        let sessionID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingPrepares.append(PendingPrepare(
                sessionID: sessionID,
                progress: progress,
                continuation: continuation
            ))
        }
    }

    func resumePrepare(at index: Int, title: String) {
        let pending = pendingPrepares[index]
        pending.continuation.resume(returning: MeetingTransferImportPresentation(
            sessionID: pending.sessionID,
            sourceMeetingID: MeetingID(),
            title: title,
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456),
            capabilities: [.notes, .audio],
            visibleSpeakerLabels: [],
            audioTracks: [.init(label: "Microphone", byteCount: 100)],
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            disposition: .new
        ))
    }

    func reportHashProgress(processedBytes: Int64, totalBytes: Int64) {
        pendingPrepares.last?.progress(MeetingTransferProgress(
            phase: .hashing,
            processedBytes: processedBytes,
            totalBytes: totalBytes
        ))
    }

    private func runImport(
        sessionID: UUID,
        choice: MeetingTransferProcessingChoice,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void
    ) async throws -> MeetingTransferImportResult {
        importCount += 1
        if let importError { throw importError }
        if importWaitsForCancellation {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                importWasCancelled = true
                throw CancellationError()
            }
        }
        if importWaitsForResume {
            return await withCheckedContinuation { continuation in
                pendingImport = continuation
            }
        }
        return .imported(MeetingID())
    }

    func resumeImport(with result: MeetingTransferImportResult) {
        pendingImport?.resume(returning: result)
        pendingImport = nil
    }

    private func discard(_ sessionID: UUID) async throws {
        discardAttempts += 1
        if discardWaitsForResume {
            await withCheckedContinuation { continuation in
                pendingDiscard = continuation
            }
        }
        if discardFailures > 0 {
            discardFailures -= 1
            throw TestCleanupError.failed
        }
        discardedSessionIDs.append(sessionID)
    }

    func resumeDiscard() {
        pendingDiscard?.resume()
        pendingDiscard = nil
    }
}

private enum TestCleanupError: Error {
    case failed
}

private actor MeetingTransferDetailHarness {
    let meetingID = MeetingID()
    let generationID = MeetingTransferGenerationID()
    private let includeGeneration: Bool
    private(set) var retryCount = 0
    private(set) var receivedGeneration: MeetingTransferGenerationID?
    private(set) var receivedLocale: String?
    private(set) var receivedModelsReady: Bool?

    init(includeGeneration: Bool = true) {
        self.includeGeneration = includeGeneration
    }

    nonisolated func client() -> MeetingTransferDetailClient {
        MeetingTransferDetailClient(
            load: { [weak self] meetingID in
                guard let self else { return nil }
                return await self.presentation(for: meetingID)
            },
            requestManualRetry: { [weak self] meetingID, generation, locale, ready in
                guard let self else { throw CancellationError() }
                try await self.retry(
                    meetingID: meetingID,
                    generation: generation,
                    locale: locale,
                    modelsReady: ready
                )
            }
        )
    }

    private func presentation(
        for requestedMeetingID: MeetingID
    ) -> MeetingTransferDetailPresentation? {
        guard requestedMeetingID == meetingID else { return nil }
        let receipt = MeetingTransferReceipt(
            sourceMeetingID: meetingID,
            sourceRevisionID: nil,
            sourcePackageContentDigest: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            sourceAppVersion: "1.0",
            includedCapabilities: [.audio],
            sourceLocaleIdentifier: "de-DE",
            sourceLocaleOrigin: .explicit,
            importGenerationID: includeGeneration ? generationID : nil
        )
        return MeetingTransferDetailPresentation.make(
            receipt: receipt,
            state: .awaitingLanguageConfirmation,
            hasAudio: true,
            requiresFreshImportRetry: false
        )
    }

    private func retry(
        meetingID requestedMeetingID: MeetingID,
        generation: MeetingTransferGenerationID,
        locale: String,
        modelsReady: Bool
    ) throws {
        guard requestedMeetingID == meetingID else { throw TestCleanupError.failed }
        retryCount += 1
        receivedGeneration = generation
        receivedLocale = locale
        receivedModelsReady = modelsReady
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStarts: [URL] = []
    private var recordedStops: [URL] = []

    var starts: [URL] { lock.withLock { recordedStarts } }
    var stops: [URL] { lock.withLock { recordedStops } }

    var client: MeetingTransferSecurityScopedResource {
        MeetingTransferSecurityScopedResource(
            startAccessing: { [weak self] url in
                self?.lock.withLock { self?.recordedStarts.append(url) }
                return true
            },
            stopAccessing: { [weak self] url in
                self?.lock.withLock { self?.recordedStops.append(url) }
            }
        )
    }
}
