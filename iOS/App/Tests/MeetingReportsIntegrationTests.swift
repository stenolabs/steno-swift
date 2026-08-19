import Foundation
import StenoDomain
import StenoIdentity
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iPad meeting reports integration")
struct MeetingReportsIntegrationTests {
    @Test("preflight reports all outbound data classes")
    @MainActor
    func preflightReportsOutboundClasses() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }

        let preflight = try await fixture.app.reportPreflight(
            for: fixture.meetingID
        )

        #expect(preflight.disclosure.classes == [
            .transcriptWithSpeakerNames,
            .participants,
            .userNotes,
        ])
    }

    @Test("unreadable notes fail before a report job is enqueued")
    @MainActor
    func unreadableNotesDoNotEnqueue() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        try Data([0xFF]).write(
            to: fixture.library.layout.userNotes(fixture.meetingID)
        )

        await #expect(throws: (any Error).self) {
            try await fixture.app.requestMeetingMinutes(
                meetingID: fixture.meetingID,
                textModelEndpointID: nil,
                preflight: preflight
            )
        }
        #expect(try await fixture.store.list().isEmpty)
    }

    @Test("report requests pin template revision endpoint and visible fingerprint")
    @MainActor
    func requestPinsInputs() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let endpointID = UUID().uuidString
        let endpointSnapshot = TextModelEndpointSnapshot(
            id: UUID(uuidString: endpointID)!,
            name: "Visible endpoint",
            baseURL: URL(string: "https://models.example.test/v1")!,
            modelID: "model-v1",
            requiresAPIKey: true
        )
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)

        let job = try await fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: endpointID,
            textModelEndpointSnapshot: endpointSnapshot,
            preflight: preflight
        )

        #expect(job.templateID == Template.meetingMinutes.id)
        #expect(job.revisionID == fixture.revisionID)
        #expect(job.textModelEndpointID == endpointID)
        #expect(job.textModelEndpointSnapshot == endpointSnapshot)
        #expect(job.templateRenderInputFingerprint == preflight.inputFingerprint)
    }

    @Test("a preflight for another meeting never enqueues")
    @MainActor
    func foreignPreflightDoesNotEnqueue() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createMeeting(
            title: "Other",
            status: .ready
        )
        _ = try await fixture.library.appendRevision(TranscriptRevision(
            meetingID: other.id,
            origin: .legacyImport,
            turns: []
        ))
        let preflight = try await fixture.app.reportPreflight(for: other.id)

        await #expect(throws: TemplateRenderPreflightError.inputChanged) {
            try await fixture.app.requestMeetingMinutes(
                meetingID: fixture.meetingID,
                textModelEndpointID: nil,
                preflight: preflight
            )
        }
        #expect(try await fixture.store.list().isEmpty)
    }

    @Test("changed prompt input never enqueues against a stale preflight")
    @MainActor
    func changedPromptInputDoesNotEnqueue() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        try await MeetingNotesStore(layout: fixture.library.layout).setNotes(
            fixture.meetingID,
            to: "Changed before enqueue"
        )

        await #expect(throws: TemplateRenderPreflightError.inputChanged) {
            try await fixture.app.requestMeetingMinutes(
                meetingID: fixture.meetingID,
                textModelEndpointID: nil,
                preflight: preflight
            )
        }
        #expect(try await fixture.store.list().isEmpty)
    }

    @Test("input changed after enqueue fails before the text provider")
    @MainActor
    func changedQueuedInputFailsBeforeProvider() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        let job = try await fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: nil,
            preflight: preflight
        )
        try await MeetingNotesStore(layout: fixture.library.layout).setNotes(
            fixture.meetingID,
            to: "Changed after enqueue"
        )

        await fixture.coordinator.start()
        try await fixture.coordinator.waitUntilIdle()
        await fixture.coordinator.stop()

        let failed = try await fixture.store.load(job.id)
        #expect(failed.status == .failed)
        #expect(
            failed.errorMessage
                == PipelineError.templateRenderInputChanged.localizedDescription
        )
        #expect(failed.failureReason == .templateRenderInputChanged)
        #expect(try await fixture.library.loadMeeting(fixture.meetingID).status == .ready)
        #expect(await fixture.provider.callCount() == 0)
    }

    @Test("jobs-first snapshot cannot lose a result committed during the read")
    @MainActor
    func jobsFirstSnapshotHandlesResultBeforeFinishedInterleaving() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        let queued = try await fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: nil,
            preflight: preflight
        )
        _ = try await fixture.store.transition(queued.id, to: .running)
        let runID = PipelineRunIdentity.runID(for: queued)
        let result = fixture.result(markdown: "INTERLEAVED_RESULT", createdAt: Date())

        let first = try await fixture.app.reportsSnapshot(
            for: fixture.meetingID,
            afterJobsLoaded: {
                try fixture.write(result, runID: runID)
                _ = try await fixture.store.transition(queued.id, to: .finished)
            }
        )
        var presentation = MeetingReportsPresentation()
        presentation.reconcile(reports: first.reports, jobs: first.jobs)

        #expect(first.jobs.count == 1)
        #expect(first.jobs.first?.status == .running)
        #expect(first.reports.count == 1)
        #expect(first.reports.first?.runID == runID)
        #expect(presentation.isPending)

        let second = try await fixture.app.reportsSnapshot(for: fixture.meetingID)
        presentation.reconcile(reports: second.reports, jobs: second.jobs)

        #expect(!presentation.isPending)
        #expect(presentation.shownReport?.runID == runID)
    }

    @Test("schema-1 Apple jobs without a fingerprint keep the compatibility path")
    @MainActor
    func legacyJobWithoutFingerprintRenders() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let job = Job(
            schemaVersion: 1,
            kind: .templateRender,
            meetingID: fixture.meetingID,
            templateID: Template.meetingMinutes.id,
            revisionID: fixture.revisionID
        )
        try await fixture.store.enqueue(job)
        let encoded = try String(
            contentsOf: fixture.library.layout.job(job.id),
            encoding: .utf8
        )

        await fixture.coordinator.start()
        try await fixture.coordinator.waitUntilIdle()
        await fixture.coordinator.stop()

        #expect(!encoded.contains("templateRenderInputFingerprint"))
        #expect(try await fixture.store.load(job.id).status == .finished)
        #expect(await fixture.provider.callCount() > 0)
    }

    @Test("concurrent report requests converge on one durable job")
    @MainActor
    func concurrentRequestsConverge() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)

        async let first = fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: nil,
            preflight: preflight
        )
        async let second = fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: nil,
            preflight: preflight
        )
        let jobs = try await [first, second]

        #expect(jobs[0].id == jobs[1].id)
        #expect(try await fixture.store.list().count == 1)
    }

    @Test("reports are newest first and jobs stay meeting scoped")
    @MainActor
    func reportsAndJobsAreMeetingScoped() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createMeeting(
            title: "Other",
            status: .ready
        )
        let old = fixture.result(markdown: "old", createdAt: .distantPast)
        let new = fixture.result(markdown: "new", createdAt: .distantFuture)
        try fixture.write(old, runID: RunID())
        try fixture.write(new, runID: RunID())
        try await fixture.store.enqueue(Job(
            kind: .templateRender,
            meetingID: fixture.meetingID
        ))
        try await fixture.store.enqueue(Job(
            kind: .templateRender,
            meetingID: other.id
        ))

        let reports = try await fixture.app.reports(for: fixture.meetingID)
        let jobs = try await fixture.app.jobs(for: fixture.meetingID)

        #expect(reports.map(\.result.markdown) == ["new", "old"])
        #expect(jobs.count == 1)
        #expect(jobs.first?.meetingID == fixture.meetingID)
    }

    @Test("queued report cancellation is persisted")
    @MainActor
    func cancellationIsPersisted() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        let job = try await fixture.app.requestMeetingMinutes(
            meetingID: fixture.meetingID,
            textModelEndpointID: nil,
            preflight: preflight
        )

        try await fixture.app.cancelReportJob(job.id)

        #expect(try await fixture.store.load(job.id).status == .cancelled)
    }

    @Test("cancelling the caller never cancels the persistent job")
    @MainActor
    func callerCancellationDoesNotCancelJob() async throws {
        let fixture = try await ReportFixture.make()
        defer { fixture.remove() }
        let preflight = try await fixture.app.reportPreflight(for: fixture.meetingID)
        let task = Task { @MainActor in
            try await fixture.app.requestMeetingMinutes(
                meetingID: fixture.meetingID,
                textModelEndpointID: nil,
                preflight: preflight
            )
        }
        let job = try await task.value

        task.cancel()

        #expect(try await fixture.store.load(job.id).status == .queued)
    }
}

private struct ReportFixture {
    let root: URL
    let library: Library
    let store: JobStore
    let coordinator: PipelineCoordinator
    let provider: ReportTextModelProvider
    let app: AppModel
    let meetingID: MeetingID
    let revisionID: RevisionID

    @MainActor
    static func make() async throws -> ReportFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-iPad-report-\(UUID().uuidString)",
            isDirectory: true
        )
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(
            title: "Report",
            status: .ready
        )
        let person = Person(displayName: "Ada Lovelace")
        try await IdentityStore(layout: library.layout).replacePersons([person])
        let diarizationRunID = RunID()
        let clusterID = "fixture/SPEAKER_0"
        let revision = TranscriptRevision(
            meetingID: meeting.id,
            origin: .legacyImport,
            turns: [TranscriptTurn(
                speaker: .cluster(
                    runID: diarizationRunID,
                    clusterID: clusterID
                ),
                start: 0,
                end: 1,
                segments: [TranscriptSegment(
                    text: "TRANSCRIPT_SENTINEL",
                    start: 0,
                    end: 1,
                    words: []
                )]
            )]
        )
        _ = try await library.appendRevision(revision)
        try await MeetingNotesStore(layout: library.layout).setNotes(
            meeting.id,
            to: "NOTE_SENTINEL"
        )
        try seedReview(
            library: library,
            meetingID: meeting.id,
            runID: diarizationRunID,
            clusterID: clusterID,
            person: person
        )
        let store = try JobStore(layout: library.layout)
        let provider = ReportTextModelProvider()
        let resolver: TextModelProviderResolver = { _ in provider }
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: store,
            providers: [:],
            textModelProviderResolver: resolver,
            locale: Locale(identifier: "de-DE")
        )
        let runtime = PipelineRuntime(
            library: library,
            jobStore: store,
            coordinator: coordinator
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            textModelProviderResolver: resolver,
            startPipeline: { _, _, receivedResolver in
                _ = try receivedResolver(TextModelProviderSelection(endpointID: nil))
                return runtime
            },
            libraryURL: root
        )
        await app.bootstrap()
        return ReportFixture(
            root: root,
            library: library,
            store: store,
            coordinator: coordinator,
            provider: provider,
            app: app,
            meetingID: meeting.id,
            revisionID: revision.id
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func result(markdown: String, createdAt: Date) -> TemplateResult {
        TemplateResult(
            markdown: markdown,
            template: .meetingMinutes,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            revisionID: revisionID,
            createdAt: createdAt
        )
    }

    func write(_ result: TemplateResult, runID: RunID) throws {
        try AtomicFile.write(
            try JSONEncoder().encode(result),
            to: library.layout.report(meetingID, runID: runID)
        )
    }
}

private actor ReportTextModelProvider: StructuredTextModelProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "ReportFixture",
        version: "1"
    )
    nonisolated let availability = TextModelAvailability.available
    private var calls = 0

    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        calls += 1
        return StructuredTemplateOutput(sections: template.generatedSections.map {
            StructuredTemplateSection(sectionID: $0.id, markdown: "fixture")
        })
    }

    func callCount() -> Int { calls }
}

private func seedReview(
    library: Library,
    meetingID: MeetingID,
    runID: RunID,
    clusterID: String,
    person: Person
) throws {
    let assetID = MediaAssetID()
    let cluster = IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: MediaAsset.Kind.imported.rawValue,
        clusterID: clusterID,
        recordingType: .imported,
        embedding: [1, 0],
        speechDurationSeconds: 1,
        segmentCount: 1,
        reviewState: .confirmed(person.id)
    )
    try writeFinishedRun(
        ProcessingRun(
            id: runID,
            meetingID: meetingID,
            kind: .diarization,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            status: .finished
        ),
        artifact: DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            revisionID: RevisionID(),
            tracks: [DiarizationTrackResult(
                assetID: assetID,
                assetKind: .imported,
                engine: EngineDescriptor(name: "fixture", version: "1"),
                segments: [DiarizationRunSegment(
                    clusterID: clusterID,
                    start: 0,
                    end: 1
                )],
                clusters: [DiarizationClusterResult(
                    clusterID: clusterID,
                    embedding: [1, 0],
                    speechDurationSeconds: 1,
                    segmentCount: 1
                )]
            )]
        ),
        artifactName: "diarization.json",
        layout: library.layout
    )
    let suggestionRunID = RunID()
    try writeFinishedRun(
        ProcessingRun(
            id: suggestionRunID,
            meetingID: meetingID,
            kind: .identitySuggestion,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            status: .finished
        ),
        artifact: IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            clusterResolutions: [IdentityClusterResolution(
                channel: MediaAsset.Kind.imported.rawValue,
                sourceClusterID: clusterID,
                primaryClusterID: clusterID
            )],
            identityEvidenceFingerprint: "fixture",
            suggestions: []
        ),
        artifactName: "suggestions.json",
        layout: library.layout
    )
    try MeetingReviewStore(layout: library.layout).save(
        MeetingReviewDocument(runID: runID, clusters: [cluster]),
        meetingID: meetingID
    )
}

private func writeFinishedRun<Artifact: Encodable>(
    _ run: ProcessingRun,
    artifact: Artifact,
    artifactName: String,
    layout: LibraryLayout
) throws {
    let directory = layout.runDirectory(run.meetingID, runID: run.id)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFile.write(
        encoder.encode(run),
        to: directory.appendingPathComponent("run.json")
    )
    try AtomicFile.write(
        encoder.encode(artifact),
        to: directory.appendingPathComponent(artifactName)
    )
}
