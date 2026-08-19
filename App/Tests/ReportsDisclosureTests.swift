import Foundation
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Reports disclosure")
struct ReportsDisclosureTests {
    @Test("Mac notice renders the shared manifest without calling the server local")
    func macNoticeUsesSharedManifest() throws {
        let disclosure = OutboundDisclosure(
            transcript: TranscriptRevision(
                meetingID: MeetingID(),
                origin: .legacyImport,
                turns: [TranscriptTurn(start: 0, end: 1, segments: [])]
            ),
            context: RenderContext(
                userNotes: "notes",
                participants: ["Ada, Example Org"]
            )
        )
        let endpoint = TextModelEndpoint(
            name: "Remote model",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: true
        )

        let notice = try ReportsDisclosurePresentation.externalNotice(
            endpoint: endpoint,
            disclosure: disclosure
        )

        for dataClass in disclosure.classes {
            #expect(notice.text.contains(dataClass.displayName))
        }
        #expect(notice.text.contains("models.example.com"))
        #expect(notice.text.contains(
            "Audio, structured profile email fields, and attachments are not added to the model input."
        ))
        #expect(notice.text.contains(
            "Email addresses written in the transcript or your notes are included with that text."
        ))
        #expect(!notice.text.contains("email addresses and attached documents stay"))
        #expect(!notice.text.contains("to this Mac"))
        #expect(!notice.isPlaintext)
    }

    @Test("the initial snapshot always reads jobs before reports")
    @MainActor
    func coldStartSnapshotCannotMissResultAndActiveJob() async {
        let meetingID = MeetingID()
        let job = Job(kind: .templateRender, meetingID: meetingID)
        let result = report("new", at: 2)
        let interleaving = ColdStartReportInterleaving(job: job, report: result)

        let snapshot = await ReportsRefreshSnapshot.load(
            pendingJobID: nil,
            reports: { await interleaving.loadReports() },
            jobs: { await interleaving.loadJobs() }
        )

        #expect(await interleaving.readOrder == [.jobs, .reports])
        #expect(
            snapshot.reports.contains(result)
                || snapshot.jobs.contains(where: {
                    $0.status == .queued || $0.status == .running
                })
        )
    }

    @Test("report start failures do not overwrite the review error channel")
    @MainActor
    func reportStartFailureDoesNotWriteReviewError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-mac-report-start-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Report", status: .ready)
        _ = try await library.appendRevision(TranscriptRevision(
            meetingID: meeting.id,
            origin: .legacyImport,
            turns: [TranscriptTurn(start: 0, end: 1, segments: [])]
        ))
        let preflight = try await TemplateRenderInputAssembler.preflight(
            library: library,
            meetingID: meeting.id
        )
        let model = AppModel()
        model.reviewError = "EXISTING_REVIEW_ERROR"

        await #expect(throws: (any Error).self) {
            _ = try await model.requestMeetingMinutes(
                meetingID: meeting.id,
                preflight: preflight
            )
        }

        #expect(model.reviewError == "EXISTING_REVIEW_ERROR")
    }

    @Test("a typed stale-input failure refreshes the visible preflight immediately")
    @MainActor
    func staleInputFailureRefreshesPreflight() async {
        var job = Job(kind: .templateRender, meetingID: MeetingID(), status: .failed)
        job.failureReason = .templateRenderInputChanged
        var refreshCount = 0

        await ReportsPendingJobObservation.refreshPreflightIfNeeded(for: job) {
            refreshCount += 1
        }

        #expect(refreshCount == 1)
    }

    @Test("a legacy external-job failure refreshes the visible preflight immediately")
    @MainActor
    func missingPinsFailureRefreshesPreflight() async {
        var job = Job(kind: .templateRender, meetingID: MeetingID(), status: .failed)
        job.failureReason = .templateRenderPinsRequired
        var refreshCount = 0

        await ReportsPendingJobObservation.refreshPreflightIfNeeded(for: job) {
            refreshCount += 1
        }

        #expect(refreshCount == 1)
    }

    @Test("an unrelated report failure does not reload the preflight")
    @MainActor
    func unrelatedFailureDoesNotRefreshPreflight() async {
        let job = Job(kind: .templateRender, meetingID: MeetingID(), status: .failed)
        var refreshCount = 0

        await ReportsPendingJobObservation.refreshPreflightIfNeeded(for: job) {
            refreshCount += 1
        }

        #expect(refreshCount == 0)
    }

    @Test("a cold latest missing-pins failure is shown and refreshed once per process")
    @MainActor
    func coldMissingPinsFailureIsObservedOnce() async {
        let ledger = TemplateRenderPinsFailureObservationLedger()
        let meetingID = MeetingID()
        let failed = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 2),
            errorMessage: "Generate the minutes again to confirm the current inputs.",
            failureReason: .templateRenderPinsRequired
        )
        let older = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            errorMessage: "OLDER_FAILURE"
        )
        var refreshCount = 0

        let first = await ReportsPendingJobObservation.observeColdPinsFailure(
            in: [older, failed],
            ledger: ledger
        ) {
            refreshCount += 1
        }
        let remount = await ReportsPendingJobObservation.observeColdPinsFailure(
            in: [older, failed],
            ledger: ledger
        ) {
            refreshCount += 1
        }

        #expect(first == failed.errorMessage)
        #expect(remount == nil)
        #expect(refreshCount == 1)
    }

    @Test("a newer terminal render suppresses an older cold missing-pins failure")
    @MainActor
    func onlyLatestColdFailureIsRelevant() async {
        let meetingID = MeetingID()
        let failed = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1),
            failureReason: .templateRenderPinsRequired
        )
        let newer = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .finished,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var refreshCount = 0

        let message = await ReportsPendingJobObservation.observeColdPinsFailure(
            in: [failed, newer],
            ledger: TemplateRenderPinsFailureObservationLedger()
        ) {
            refreshCount += 1
        }

        #expect(message == nil)
        #expect(refreshCount == 0)
    }

    @Test("pending status names the same pinned endpoint as its disclosure")
    func pendingStatusUsesPinnedEndpoint() {
        let pinned = TextModelEndpointSnapshot(
            id: UUID(),
            name: "Pinned host",
            baseURL: URL(string: "https://pinned.example/v1")!,
            modelID: "pinned-model",
            requiresAPIKey: true
        )
        let display = ReportTextModelDisplay.external(pinned)

        #expect(
            ReportsPendingJobObservation.statusLabel(for: display)
                == "Generating with Pinned host · pinned-model (external)…"
        )
        #expect(display.endpointSnapshot == pinned)
    }

    private func report(_ markdown: String, at timestamp: TimeInterval) -> StoredTemplateResult {
        StoredTemplateResult(
            runID: RunID(),
            result: TemplateResult(
                markdown: markdown,
                template: .meetingMinutes,
                engine: EngineDescriptor(name: "fixture", version: "1"),
                revisionID: RevisionID(),
                createdAt: Date(timeIntervalSince1970: timestamp)
            )
        )
    }
}

private actor ColdStartReportInterleaving {
    enum Read: Equatable {
        case jobs
        case reports
    }

    private var job: Job
    private var reports: [StoredTemplateResult] = []
    private let report: StoredTemplateResult
    private(set) var readOrder: [Read] = []

    init(job: Job, report: StoredTemplateResult) {
        self.job = job
        self.report = report
    }

    func loadJobs() -> [Job] {
        readOrder.append(.jobs)
        let snapshot = [job]
        persistReportAndFinishJob()
        return snapshot
    }

    func loadReports() -> [StoredTemplateResult] {
        readOrder.append(.reports)
        let snapshot = reports
        persistReportAndFinishJob()
        return snapshot
    }

    private func persistReportAndFinishJob() {
        guard reports.isEmpty else { return }
        reports = [report]
        job.status = .finished
    }
}
