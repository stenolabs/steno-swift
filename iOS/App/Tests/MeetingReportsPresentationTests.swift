import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import Testing
@testable import Steno

@Suite("Meeting reports presentation")
struct MeetingReportsPresentationTests {
    @Test("generation gate is synchronous")
    func generationGateIsSynchronous() {
        var state = MeetingReportsPresentation()
        state.reconcile(reports: [], jobs: [])

        let first = state.beginGeneration()
        let second = state.beginGeneration()

        #expect(first)
        #expect(!second)
        #expect(state.isStarting)
    }

    @Test("generation waits for the first reports and jobs snapshot")
    func generationWaitsForInitialSnapshot() {
        var state = MeetingReportsPresentation()

        #expect(!state.canBeginGeneration)
        let rejected = state.beginGeneration()
        #expect(!rejected)

        state.reconcile(reports: [], jobs: [])

        #expect(state.hasReconciledSnapshot)
        #expect(state.canBeginGeneration)
        let accepted = state.beginGeneration()
        #expect(accepted)
    }

    @Test("a successful retry clears the first snapshot error and unlocks generation")
    func successfulInitialSnapshotRetryUnlocksGeneration() {
        var state = MeetingReportsPresentation()
        state.snapshotFailed("FIRST_SNAPSHOT_FAILED")

        #expect(!state.hasReconciledSnapshot)
        #expect(!state.canBeginGeneration)
        #expect(state.errorMessage == "FIRST_SNAPSHOT_FAILED")

        state.reconcile(reports: [], jobs: [])

        #expect(state.hasReconciledSnapshot)
        #expect(state.canBeginGeneration)
        #expect(state.errorMessage == nil)
    }

    @Test("a successful retry recognizes an existing persistent job")
    func successfulInitialSnapshotRetryRecognizesJob() {
        let old = report("old", at: 1)
        let active = job(status: .running)
        var state = MeetingReportsPresentation()
        state.snapshotFailed("FIRST_SNAPSHOT_FAILED")

        state.reconcile(reports: [old], jobs: [active])

        #expect(state.hasReconciledSnapshot)
        #expect(state.errorMessage == nil)
        #expect(state.pendingJobID == active.id)
        #expect(state.shownReport == old)
        #expect(!state.canBeginGeneration)
    }

    @Test("a later snapshot does not erase an action error")
    func snapshotDoesNotEraseActionError() {
        var state = MeetingReportsPresentation()
        state.reconcile(reports: [], jobs: [])
        state.actionFailed("CANCEL_FAILED")

        state.reconcile(reports: [], jobs: [])

        #expect(state.errorMessage == "CANCEL_FAILED")
    }

    @Test("an existing job from another endpoint uses the visible reports as its baseline")
    func existingDifferentEndpointJobUsesSnapshotBaseline() {
        let meetingID = MeetingID()
        let old = report("old", at: 1)
        var active = Job(
            kind: .templateRender,
            meetingID: meetingID,
            textModelEndpointID: "endpoint-used-by-persistent-job",
            status: .running
        )
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [old], jobs: [active])

        #expect(state.pendingJobID == active.id)
        #expect(!state.canBeginGeneration)

        active.status = .finished
        let new = report(
            "new",
            at: 2,
            runID: PipelineRunIdentity.runID(for: active)
        )
        state.reconcile(reports: [new, old], jobs: [active])

        #expect(state.shownReport == new)
        #expect(!state.isPending)
    }

    @Test("an existing report stays visible while its replacement runs")
    func existingReportStaysVisible() {
        let old = report("old", at: 1)
        let queued = job(status: .queued)
        var running = queued
        running.status = .running
        var state = MeetingReportsPresentation(reports: [old])

        state.accepted(job: queued)
        state.reconcile(reports: [old], jobs: [running])

        #expect(state.shownReport == old)
        #expect(state.isPending)
    }

    @Test("a completed replacement selects the newest result")
    func completedReplacementSelectsNewest() {
        let old = report("old", at: 1)
        var finished = job(status: .queued)
        let new = report(
            "new",
            at: 2,
            runID: PipelineRunIdentity.runID(for: finished)
        )
        var state = MeetingReportsPresentation(reports: [old])
        state.accepted(job: finished)
        finished.status = .finished

        state.reconcile(reports: [new, old], jobs: [finished])

        #expect(state.shownReport == new)
        #expect(!state.isPending)
    }

    @Test("a result that arrives after its finished job becomes selected")
    func lateCompletedReportBecomesSelected() {
        let old = report("old", at: 1)
        let queued = job(status: .queued)
        let new = report(
            "new",
            at: 2,
            runID: PipelineRunIdentity.runID(for: queued)
        )
        var running = queued
        running.status = .running
        var finished = queued
        finished.status = .finished
        var state = MeetingReportsPresentation(reports: [old])

        state.accepted(job: queued)
        state.reconcile(reports: [old], jobs: [running])

        state.reconcile(reports: [new, old], jobs: [finished])

        #expect(state.shownReport == new)
        #expect(!state.isPending)
    }

    @Test("a newly accepted generation resets an older manual selection")
    func newGenerationResetsManualSelection() {
        let old = report("old", at: 1)
        let queued = job(status: .queued)
        let new = report(
            "new",
            at: 2,
            runID: PipelineRunIdentity.runID(for: queued)
        )
        var finished = queued
        finished.status = .finished
        var state = MeetingReportsPresentation(reports: [old])

        state.select(old.runID)
        state.accepted(job: queued)
        state.reconcile(reports: [new, old], jobs: [finished])

        #expect(state.shownReport == new)
        #expect(!state.isPending)
    }

    @Test("a finished render without a new result stops polling")
    func finishedRenderWithoutNewResultStopsPolling() {
        let old = report("old", at: 1)
        let queued = job(status: .queued)
        var finished = queued
        finished.status = .finished
        var state = MeetingReportsPresentation(reports: [old])

        state.accepted(job: queued)
        #expect(state.isPending)
        state.reconcile(reports: [old], jobs: [finished])
        #expect(!state.isPending)
        #expect(state.errorMessage == "The minutes finished without a readable result.")
    }

    @Test("failure preserves an explicitly selected older version")
    func failurePreservesSelection() {
        let old = report("old", at: 1)
        let new = report("new", at: 2)
        var failed = job(status: .queued)
        var state = MeetingReportsPresentation(reports: [new, old])
        state.select(old.runID)
        state.accepted(job: failed)
        failed.status = .failed
        failed.errorMessage = "MODEL_FAILED"

        state.reconcile(reports: [new, old], jobs: [failed])

        #expect(state.shownReport == old)
        #expect(state.errorMessage == "MODEL_FAILED")
    }

    @Test("historical failures do not become the current banner")
    func historicalFailuresStayHistorical() {
        var failed = job(status: .failed)
        failed.errorMessage = "OLD_FAILURE"
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [], jobs: [failed])

        #expect(state.errorMessage == nil)
        #expect(!state.isPending)
    }

    @Test("a result persisted before job completion remains pending until that exact job finishes")
    func resultBeforeFinishedRemainsPending() {
        var running = job(status: .running)
        let exact = report(
            "exact",
            at: 2,
            runID: PipelineRunIdentity.runID(for: running)
        )
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [exact], jobs: [running])
        #expect(state.isPending)

        running.status = .finished
        state.reconcile(reports: [exact], jobs: [running])
        #expect(!state.isPending)
        #expect(state.shownReport == exact)
    }

    @Test("a crash-recovered queued job owns its already committed exact result")
    func crashRecoveredJobKeepsExactResultPending() {
        var recovered = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            textModelEndpointID: UUID().uuidString,
            status: .queued
        )
        let exact = report(
            "committed before crash",
            at: 2,
            runID: PipelineRunIdentity.runID(for: recovered)
        )
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [exact], jobs: [recovered])
        #expect(state.isPending)

        recovered.status = .finished
        state.reconcile(reports: [exact], jobs: [recovered])
        #expect(!state.isPending)
        #expect(state.shownReport == exact)
    }

    @Test("parallel unrelated results cannot satisfy the observed job")
    func parallelResultDoesNotSatisfyObservedJob() {
        var observed = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            textModelEndpointID: "provider-a",
            status: .running
        )
        let other = Job(
            kind: .templateRender,
            meetingID: observed.meetingID,
            textModelEndpointID: "provider-b",
            status: .finished
        )
        let unrelated = report(
            "other provider",
            at: 3,
            runID: PipelineRunIdentity.runID(for: other)
        )
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [unrelated], jobs: [observed, other])
        observed.status = .finished
        state.reconcile(reports: [unrelated], jobs: [observed, other])

        #expect(!state.isPending)
        #expect(state.errorMessage == "The minutes finished without a readable result.")
        #expect(state.shownReport == unrelated)
    }

    @Test("a terminal observed job hands polling directly to the next active job")
    func terminalJobAdoptsNextActiveJobInSameSnapshot() {
        var first = job(status: .queued)
        let second = Job(
            kind: .templateRender,
            meetingID: first.meetingID,
            textModelEndpointID: "provider-b",
            status: .running
        )
        let firstResult = report(
            "first",
            at: 1,
            runID: PipelineRunIdentity.runID(for: first)
        )
        var state = MeetingReportsPresentation()
        state.accepted(job: first)
        first.status = .finished

        state.reconcile(reports: [firstResult], jobs: [first, second])

        #expect(state.pendingJobID == second.id)
        #expect(state.isPending)
        #expect(!state.canBeginGeneration)
        #expect(state.shownReport == firstResult)

        var finishedSecond = second
        finishedSecond.status = .finished
        let secondResult = report(
            "second",
            at: 2,
            runID: PipelineRunIdentity.runID(for: second)
        )
        state.reconcile(
            reports: [secondResult, firstResult],
            jobs: [first, finishedSecond]
        )

        #expect(!state.isPending)
        #expect(state.shownReport == secondResult)
    }

    @Test("pending disclosure remains pinned when another scene changes selection")
    func pendingDisclosureUsesJobSnapshot() {
        let pinned = TextModelEndpointSnapshot(
            id: UUID(),
            name: "Pinned host",
            baseURL: URL(string: "https://pinned.example.test/v1")!,
            modelID: "pinned-model",
            requiresAPIKey: true
        )
        let active = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            textModelEndpointID: pinned.id.uuidString,
            textModelEndpointSnapshot: pinned,
            status: .running
        )
        var state = MeetingReportsPresentation()

        state.reconcile(reports: [], jobs: [active])

        #expect(state.pendingEndpointSnapshot == pinned)
        #expect(state.pendingEndpointID == pinned.id.uuidString)
    }

    @Test("template input failure requests one immediate preflight refresh")
    func inputFailureRequestsPreflightRefresh() {
        var failed = job(status: .failed)
        failed.failureReason = .templateRenderInputChanged
        var state = MeetingReportsPresentation()
        state.accepted(job: failed)

        state.reconcile(reports: [], jobs: [failed])

        let firstRequest = state.consumePreflightRefreshRequest()
        let secondRequest = state.consumePreflightRefreshRequest()
        #expect(firstRequest)
        #expect(!secondRequest)
    }

    @Test("legacy external-job failure requests one immediate preflight refresh")
    func missingPinsFailureRequestsPreflightRefresh() {
        var failed = job(status: .failed)
        failed.failureReason = .templateRenderPinsRequired
        var state = MeetingReportsPresentation()
        state.accepted(job: failed)

        state.reconcile(reports: [], jobs: [failed])

        let firstRequest = state.consumePreflightRefreshRequest()
        let secondRequest = state.consumePreflightRefreshRequest()
        #expect(firstRequest)
        #expect(!secondRequest)
    }

    @Test("a cold latest missing-pins failure is actionable and refreshes once")
    func coldMissingPinsFailureIsObservedOnce() {
        let ledger = TemplateRenderPinsFailureObservationLedger()
        var failed = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 2),
            errorMessage: "Generate the minutes again to confirm the current inputs.",
            failureReason: .templateRenderPinsRequired
        )
        let older = Job(
            kind: .templateRender,
            meetingID: failed.meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            errorMessage: "OLDER_FAILURE"
        )
        var state = MeetingReportsPresentation(failureLedger: ledger)

        state.reconcile(reports: [], jobs: [older, failed])

        let observedMessage = state.errorMessage
        let couldBeginGeneration = state.canBeginGeneration
        let firstRefresh = state.consumePreflightRefreshRequest()
        let repeatedRefresh = state.consumePreflightRefreshRequest()
        let beganGeneration = state.beginGeneration()
        #expect(observedMessage == failed.errorMessage)
        #expect(firstRefresh)
        #expect(!repeatedRefresh)
        #expect(couldBeginGeneration)
        #expect(beganGeneration)
        #expect(state.errorMessage == nil)

        failed.status = .failed
        var remounted = MeetingReportsPresentation(failureLedger: ledger)
        remounted.reconcile(reports: [], jobs: [older, failed])
        let remountedRefresh = remounted.consumePreflightRefreshRequest()
        #expect(remounted.errorMessage == nil)
        #expect(!remountedRefresh)
    }

    @Test("a newer terminal job suppresses an older cold missing-pins failure")
    func onlyLatestTemplateFailureIsRelevantOnColdOpen() {
        let meetingID = MeetingID()
        let failed = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            errorMessage: "OLD_PINS_FAILURE",
            failureReason: .templateRenderPinsRequired
        )
        let newer = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .finished,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var state = MeetingReportsPresentation(
            failureLedger: TemplateRenderPinsFailureObservationLedger()
        )

        state.reconcile(reports: [], jobs: [failed, newer])

        let requestedRefresh = state.consumePreflightRefreshRequest()
        #expect(state.errorMessage == nil)
        #expect(!requestedRefresh)
        #expect(state.canBeginGeneration)
    }

    @Test("deleted selection falls back and cancellation keeps the report")
    func deletionAndCancellationKeepTruthfulSelection() {
        let old = report("old", at: 1)
        let new = report("new", at: 2)
        var cancelled = job(status: .queued)
        var state = MeetingReportsPresentation(reports: [new, old])
        state.select(old.runID)
        state.accepted(job: cancelled)
        cancelled.status = .cancelled

        state.reconcile(reports: [new], jobs: [cancelled])

        #expect(state.shownReport == new)
        #expect(state.errorMessage == nil)
        #expect(!state.isPending)
    }

    @Test("engine and share labels describe the selected immutable result")
    func engineAndShareLabels() {
        let stored = report("SHARE_SENTINEL", at: 1, modelVersion: "gemma-3")

        #expect(MeetingReportsPresentation.engineLabel(stored.result.engine)
            == "fixture · gemma-3")
        #expect(ReportSharePayload(report: stored).text == "SHARE_SENTINEL")
    }

    @Test("version labels distinguish reports created seconds apart")
    func versionLabelsIncludeSecondsAndSelectionIsExplicit() {
        let first = report("first", at: 1)
        let second = report("second", at: 2)
        var state = MeetingReportsPresentation(reports: [second, first])
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let firstLabel = MeetingReportsPresentation.versionLabel(
            first,
            locale: locale,
            timeZone: timeZone
        )
        let secondLabel = MeetingReportsPresentation.versionLabel(
            second,
            locale: locale,
            timeZone: timeZone
        )

        #expect(firstLabel != secondLabel)
        #expect(state.isShownVersion(second))
        #expect(!state.isShownVersion(first))

        state.select(first.runID)

        #expect(state.isShownVersion(first))
        #expect(!state.isShownVersion(second))
    }

    @Test(
        "Apple availability maps all states",
        arguments: [
            (TextModelAvailability.available, true, String?.none),
            (
                .unavailable(.deviceNotEligible),
                false,
                "Dieses Gerät unterstützt Apple Intelligence nicht."
            ),
            (
                .unavailable(.appleIntelligenceNotEnabled),
                false,
                "Apple Intelligence ist nicht aktiviert."
            ),
            (
                .unavailable(.modelNotReady),
                false,
                "Das Apple-Intelligence-Modell ist noch nicht verfügbar."
            ),
            (
                .unavailable(.unknown),
                false,
                "Das Textmodell ist derzeit nicht verfügbar."
            ),
        ]
    )
    func appleAvailability(
        availability: TextModelAvailability,
        canGenerate: Bool,
        message: String?
    ) {
        let presentation = MeetingReportsAvailabilityPresentation(availability)

        #expect(presentation.canGenerate == canGenerate)
        #expect(presentation.message == message)
    }

    @Test("external notice names exactly the outbound classes")
    func externalNoticeNamesExactClasses() throws {
        for mask in 0..<8 {
            let disclosure = disclosure(
                transcript: mask & 1 != 0,
                participants: mask & 2 != 0,
                notes: mask & 4 != 0
            )
            let endpoint = TextModelEndpoint(
                name: "LM Studio",
                baseURL: URL(string: "https://models.example.com/v1")!,
                modelID: "gemma-3",
                requiresAPIKey: true
            )

            let notice = try ExternalModelNotice(
                endpoint: endpoint,
                disclosure: disclosure,
                localDeviceDescription: "this iPad"
            )

            #expect(notice.text.contains("LM Studio"))
            #expect(notice.text.contains("models.example.com"))
            #expect(!notice.text.contains("/v1"))
            #expect(!notice.text.contains("gemma-3"))
            #expect(notice.text.contains(
                "Audio, structured profile email fields, and attachments are not added to the model input."
            ))
            #expect(notice.text.contains(
                "Email addresses written in the transcript or your notes are included with that text."
            ))
            #expect(!notice.text.contains("email addresses and attached documents stay"))
            for dataClass in PromptDataClass.allCases {
                #expect(
                    notice.text.components(separatedBy: dataClass.displayName).count - 1
                        == (disclosure.classes.contains(dataClass) ? 1 : 0)
                )
            }
        }
    }

    @Test("local HTTP notice is explicit about plaintext")
    func localHTTPNoticeIsExplicit() throws {
        let endpoint = TextModelEndpoint(
            name: "LM Studio",
            baseURL: URL(string: "http://100.64.1.2:1234/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: false
        )

        let notice = try ExternalModelNotice(
            endpoint: endpoint,
            disclosure: disclosure(transcript: true, participants: false, notes: false),
            localDeviceDescription: "this iPad"
        )

        #expect(notice.isPlaintext)
        #expect(notice.text.contains("not encrypted"))
    }

    private func job(status: Job.Status) -> Job {
        Job(kind: .templateRender, meetingID: MeetingID(), status: status)
    }

    private func report(
        _ markdown: String,
        at timestamp: TimeInterval,
        modelVersion: String? = nil,
        runID: RunID = RunID()
    ) -> StoredTemplateResult {
        StoredTemplateResult(
            runID: runID,
            result: TemplateResult(
                markdown: markdown,
                template: .meetingMinutes,
                engine: EngineDescriptor(
                    name: "fixture",
                    version: "1",
                    modelVersion: modelVersion
                ),
                revisionID: RevisionID(),
                createdAt: Date(timeIntervalSince1970: timestamp)
            )
        )
    }

    private func disclosure(
        transcript: Bool,
        participants: Bool,
        notes: Bool
    ) -> OutboundDisclosure {
        OutboundDisclosure(
            transcript: TranscriptRevision(
                meetingID: MeetingID(),
                origin: .legacyImport,
                turns: transcript ? [TranscriptTurn(start: 0, end: 1, segments: [])] : []
            ),
            context: RenderContext(
                userNotes: notes ? "notes" : nil,
                participants: participants ? ["Ada"] : []
            )
        )
    }
}
