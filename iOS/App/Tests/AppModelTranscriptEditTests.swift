import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS AppModel transcript edits", .serialized)
struct AppModelTranscriptEditTests {

    @Test("saving appends a user revision and leaves the recognised revision intact")
    @MainActor
    func saveAppendsImmutableRevision() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 1,
            text: "Corrected second line"
        )

        let edited: TranscriptRevision
        switch result {
        case .saved(let revision):
            edited = revision
        default:
            Issue.record("Expected a saved revision, got \(result)")
            return
        }
        #expect(edited.origin == .userEdit(fixture.original.id))
        #expect(edited.turns[1].segments.map(\.text) == ["Corrected second line"])
        #expect(edited.turns[1].speaker == fixture.original.turns[1].speaker)
        #expect(edited.turns[1].start == fixture.original.turns[1].start)
        #expect(edited.turns[1].end == fixture.original.turns[1].end)
        #expect(edited.turns[1].segments[0].words.isEmpty)
        #expect(edited.turns[0] == fixture.original.turns[0])
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == edited
        )
        #expect(
            try await fixture.library.loadRevision(
                fixture.original.id,
                meetingID: fixture.meeting.id
            ) == fixture.original
        )
    }

    @Test("a stale correction reports the conflict and returns the current revision")
    @MainActor
    func staleEditReloadsCurrentRevision() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let newer = try TranscriptEdit.replacingText(
            in: fixture.original,
            turnIndex: 0,
            with: "A correction from another window"
        )
        _ = try await fixture.library.appendRevision(newer)

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "My now stale correction"
        )

        #expect(
            result == .failed(.revisionConflict(currentRevision: newer))
        )
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == newer
        )
    }

    @Test("demo transcripts use the same immutable user-revision path")
    @MainActor
    func demoMeetingCanBeCorrected() async throws {
        let provenance = DemoProvenance(
            datasetID: "synthetic-demo",
            datasetVersion: "1",
            itemID: "meeting"
        )
        let fixture = try await TranscriptCorrectionFixture.make(
            metadata: MeetingMetadata(demoProvenance: provenance),
            origin: .demo(provenance)
        )
        defer { fixture.remove() }

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "Edited demo line"
        )

        guard case .saved(let edited) = result else {
            Issue.record("Expected a saved demo revision, got \(result)")
            return
        }
        #expect(edited.origin == .userEdit(fixture.original.id))
        #expect(edited.turns[0].segments.map(\.text) == ["Edited demo line"])
    }

    @Test("an overlapping library action is rejected before it can write")
    @MainActor
    func overlappingActionIsRejected() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let operation = try #require(fixture.app.beginLibraryOperation())
        #expect(fixture.app.libraryActionIsInFlight)
        defer { fixture.app.endFolderOperation(operation) }

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "Must not be saved"
        )

        #expect(result == .failed(.conflictingActionInFlight))
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == fixture.original
        )
    }

    @Test("wrong meeting, empty text, and a missing turn stay distinct")
    @MainActor
    func validationErrorsAreTyped() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }

        let wrongMeeting = await fixture.app.saveTranscriptEdit(
            meetingID: MeetingID(),
            revision: fixture.original,
            turnIndex: 0,
            text: "Correction"
        )
        let empty = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "  \n "
        )
        let missingTurn = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 99,
            text: "Correction"
        )

        #expect(wrongMeeting == .failed(.wrongMeeting))
        #expect(empty == .failed(.emptyText))
        #expect(missingTurn == .failed(.turnOutOfRange))
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == fixture.original
        )
    }

    @Test("unchanged text writes no new revision")
    @MainActor
    func unchangedTextIsANoop() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let revisionsURL = fixture.library.layout.revisionsDirectory(
            fixture.meeting.id
        )
        let before = try FileManager.default.contentsOfDirectory(
            at: revisionsURL,
            includingPropertiesForKeys: nil
        )

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "  Recognised first line  "
        )

        let after = try FileManager.default.contentsOfDirectory(
            at: revisionsURL,
            includingPropertiesForKeys: nil
        )
        #expect(result == .unchanged)
        #expect(after.count == before.count)
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == fixture.original
        )
    }

    @Test("a revision-producing job blocks correction before it writes")
    @MainActor
    func processingJobBlocksCorrection() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        try await fixture.jobStore.enqueue(Job(
            kind: .finalASR,
            meetingID: fixture.meeting.id,
            status: .running
        ))

        let result = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "Must wait"
        )

        #expect(result == .failed(.processingInFlight))
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == fixture.original
        )
    }

    @Test("two suspended saves for one meeting cannot overlap")
    @MainActor
    func simultaneousSavesAreSerialized() async throws {
        let gate = TranscriptEditSuspensionGate()
        let fixture = try await TranscriptCorrectionFixture.make(
            beforeTranscriptEditAppend: { await gate.enterAndWait() }
        )
        defer { fixture.remove() }

        let first = Task { @MainActor in
            await fixture.app.saveTranscriptEdit(
                meetingID: fixture.meeting.id,
                revision: fixture.original,
                turnIndex: 0,
                text: "First correction"
            )
        }
        await gate.waitUntilEntered()
        let second = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 1,
            text: "Second correction"
        )
        await gate.release()
        let firstResult = await first.value

        guard case .saved = firstResult else {
            Issue.record("Expected the first save to finish, got \(firstResult)")
            return
        }
        #expect(second == .failed(.editInFlight))
    }

    @Test("a later automatic revision remains pending until its exact pair is adopted")
    @MainActor
    func pendingRevisionRequiresExplicitExactAdoption() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let editResult = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "User correction"
        )
        guard case .saved(let edited) = editResult else {
            Issue.record("Expected user edit, got \(editResult)")
            return
        }
        let automaticRunID = RunID()
        try fixture.writeProcessingRun(automaticRunID, kind: .finalASR)
        let automatic = fixture.revision(
            origin: .finalRun(automaticRunID),
            texts: ["Automatic replacement", "Automatic second line"]
        )
        _ = try await fixture.library.appendRevision(automatic)

        #expect(await fixture.app.pendingTranscript(for: fixture.meeting.id) == automatic)
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == edited
        )

        let adopted = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: edited.id,
            expectedCandidateID: automatic.id
        )

        #expect(adopted == .adopted)
        #expect(await fixture.app.pendingTranscript(for: fixture.meeting.id) == nil)
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == automatic
        )
        #expect(
            try await fixture.library.loadRevision(
                edited.id,
                meetingID: fixture.meeting.id
            ) == edited
        )
    }

    @Test("stale current and candidate IDs adopt nothing")
    @MainActor
    func stalePendingPairsAreRejected() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let firstEdit = try TranscriptEdit.replacingText(
            in: fixture.original,
            turnIndex: 0,
            with: "First user edit"
        )
        _ = try await fixture.library.appendRevision(firstEdit)
        let firstCandidateRunID = RunID()
        try fixture.writeProcessingRun(firstCandidateRunID, kind: .finalASR)
        let firstCandidate = fixture.revision(
            origin: .finalRun(firstCandidateRunID),
            texts: ["First candidate", "Second line"]
        )
        _ = try await fixture.library.appendRevision(firstCandidate)

        let secondEdit = try TranscriptEdit.replacingText(
            in: firstEdit,
            turnIndex: 1,
            with: "Second user edit"
        )
        _ = try await fixture.library.appendRevision(secondEdit)
        let staleCurrentAdoption = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: firstEdit.id,
            expectedCandidateID: firstCandidate.id
        )
        #expect(staleCurrentAdoption == .staleRevisionPair)

        let secondCandidateRunID = RunID()
        try fixture.writeProcessingRun(secondCandidateRunID, kind: .finalASR)
        let secondCandidate = fixture.revision(
            origin: .finalRun(secondCandidateRunID),
            texts: ["Second candidate", "Second line"]
        )
        _ = try await fixture.library.appendRevision(secondCandidate)
        let staleCandidateAdoption = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: secondEdit.id,
            expectedCandidateID: firstCandidate.id
        )
        #expect(staleCandidateAdoption == .staleRevisionPair)

        let pointerBeforeExactAdoption = try await fixture.library
            .loadCurrentRevisionPointer(meetingID: fixture.meeting.id)
        #expect(pointerBeforeExactAdoption.currentRevisionID == secondEdit.id)
        #expect(pointerBeforeExactAdoption.pendingCandidate == secondCandidate.id)

        let exactAdoption = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: secondEdit.id,
            expectedCandidateID: secondCandidate.id
        )
        #expect(exactAdoption == .adopted)
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == secondCandidate
        )
    }

    @Test("pending speaker separation is excluded from generic transcript adoption")
    @MainActor
    func pendingDiarizationUsesOnlyItsDedicatedAdoptionPath() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let sourceRunID = try #require(fixture.originalRunID)
        let editResult = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "User correction"
        )
        guard case .saved(let edited) = editResult else {
            Issue.record("Expected user edit, got \(editResult)")
            return
        }

        let job = Job(
            kind: .diarization,
            meetingID: fixture.meeting.id,
            sourceRunID: sourceRunID,
            status: .finished
        )
        let runID = RunID()
        let candidateID = RevisionID()
        try fixture.writeProcessingRun(runID, kind: .diarization)
        try JSONEncoder().encode(DiarizationArtifact(
            jobID: job.id,
            sourceRunID: sourceRunID,
            revisionID: candidateID,
            tracks: []
        )).write(to: fixture.library.layout.runDiarization(
            fixture.meeting.id,
            runID: runID
        ))
        try await fixture.jobStore.enqueue(job)
        let candidate = fixture.revision(
            id: candidateID,
            origin: .finalRun(runID),
            texts: ["Speaker-separated candidate", "Second line"]
        )
        _ = try await fixture.library.appendRevision(candidate)

        #expect(
            try await MeetingDiarizationRequest.status(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                modelsReady: true
            ) == .resultsPending
        )
        let diarizationSnapshot = try #require(
            await fixture.app.pendingTranscriptSnapshot(
                for: fixture.meeting.id
            )
        )
        #expect(
            diarizationSnapshot.pendingClassification
                == .diarization(candidate.id)
        )
        #expect(diarizationSnapshot.pointer == CurrentRevisionPointer(
            currentRevisionID: edited.id,
            pendingCandidate: candidate.id
        ))
        #expect(await fixture.app.pendingTranscript(for: fixture.meeting.id) == nil)

        let result = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: edited.id,
            expectedCandidateID: candidate.id
        )

        #expect(result == .diarizationCandidate)
        #expect(
            try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == edited
        )
    }

    @Test("a genuine final-ASR rerun remains available for generic adoption")
    @MainActor
    func pendingFinalASRRerunIsVisible() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let editResult = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "User correction"
        )
        guard case .saved(let edited) = editResult else {
            Issue.record("Expected user edit, got \(editResult)")
            return
        }
        let rerunID = RunID()
        try fixture.writeProcessingRun(rerunID, kind: .finalASR)
        let rerun = fixture.revision(
            origin: .finalRun(rerunID),
            texts: ["New automatic transcript", "Second line"]
        )
        _ = try await fixture.library.appendRevision(rerun)

        let rerunSnapshot = try #require(
            await fixture.app.pendingTranscriptSnapshot(
                for: fixture.meeting.id
            )
        )
        #expect(rerunSnapshot.pendingClassification == .transcription(rerun))
        #expect(rerunSnapshot.pointer == CurrentRevisionPointer(
            currentRevisionID: edited.id,
            pendingCandidate: rerun.id
        ))
        #expect(await fixture.app.pendingTranscript(for: fixture.meeting.id) == rerun)
        #expect(
            await fixture.app.adoptPendingTranscript(
                meetingID: fixture.meeting.id,
                expectedCurrentRevisionID: edited.id,
                expectedCandidateID: rerun.id
            ) == .adopted
        )
    }

    @Test("edit, global action, and processing blockers remain distinct")
    @MainActor
    func pendingAdoptionBlockersAreTyped() async throws {
        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let editResult = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "User correction"
        )
        guard case .saved(let edited) = editResult else {
            Issue.record("Expected user edit, got \(editResult)")
            return
        }
        let rerun = fixture.revision(
            origin: .finalRun(RunID()),
            texts: ["Candidate", "Second line"]
        )
        _ = try await fixture.library.appendRevision(rerun)

        fixture.app.transcriptEditsInFlight.insert(fixture.meeting.id)
        let editBlocked = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: edited.id,
            expectedCandidateID: rerun.id
        )
        fixture.app.transcriptEditsInFlight.remove(fixture.meeting.id)
        #expect(editBlocked == .blocked(.editInFlight))

        let operation = try #require(fixture.app.beginLibraryOperation())
        let actionBlocked = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: edited.id,
            expectedCandidateID: rerun.id
        )
        fixture.app.endFolderOperation(operation)
        #expect(actionBlocked == .blocked(.conflictingActionInFlight))

        try await fixture.jobStore.enqueue(Job(
            kind: .finalASR,
            meetingID: fixture.meeting.id,
            status: .running
        ))
        let processingBlocked = await fixture.app.adoptPendingTranscript(
            meetingID: fixture.meeting.id,
            expectedCurrentRevisionID: edited.id,
            expectedCandidateID: rerun.id
        )
        #expect(processingBlocked == .blocked(.processingInFlight))
    }

    @Test("runtime and persistence adoption failures remain distinct")
    @MainActor
    func pendingAdoptionFailuresAreTyped() async throws {
        let missingRuntimeRoot = FileManager.default.temporaryDirectory.appending(
            path: "Steno-TranscriptMissingRuntimeTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: missingRuntimeRoot) }
        let unbootstrapped = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            libraryURL: missingRuntimeRoot
        )
        #expect(
            await unbootstrapped.adoptPendingTranscript(
                meetingID: MeetingID(),
                expectedCurrentRevisionID: RevisionID(),
                expectedCandidateID: RevisionID()
            ) == .failed(.libraryUnavailable)
        )

        let fixture = try await TranscriptCorrectionFixture.make()
        defer { fixture.remove() }
        let editResult = await fixture.app.saveTranscriptEdit(
            meetingID: fixture.meeting.id,
            revision: fixture.original,
            turnIndex: 0,
            text: "User correction"
        )
        guard case .saved(let edited) = editResult else {
            Issue.record("Expected user edit, got \(editResult)")
            return
        }
        let rerun = fixture.revision(
            origin: .finalRun(RunID()),
            texts: ["Candidate", "Second line"]
        )
        _ = try await fixture.library.appendRevision(rerun)
        try FileManager.default.removeItem(at: fixture.library.layout.revision(
            fixture.meeting.id,
            revisionID: rerun.id
        ))

        #expect(
            await fixture.app.adoptPendingTranscript(
                meetingID: fixture.meeting.id,
                expectedCurrentRevisionID: edited.id,
                expectedCandidateID: rerun.id
            ) == .failed(.persistenceFailure)
        )
    }

}

private struct TranscriptCorrectionFixture {
    let root: URL
    let library: Library
    let app: AppModel
    let meeting: Meeting
    let original: TranscriptRevision
    let jobStore: JobStore

    var originalRunID: RunID? {
        guard case .finalRun(let runID) = original.origin else { return nil }
        return runID
    }

    @MainActor
    static func make(
        metadata: MeetingMetadata? = nil,
        origin: TranscriptOrigin = .finalRun(RunID()),
        beforeTranscriptEditAppend: @escaping @Sendable () async -> Void = {}
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-TranscriptCorrectionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
        let library = try Library.open(at: libraryRoot)
        let meeting = try await library.createMeeting(
            title: "Correction",
            status: .ready,
            metadata: metadata
        )
        let original = TranscriptRevision(
            meetingID: meeting.id,
            origin: origin,
            turns: [
                TranscriptTurn(
                    speaker: .channel("Other"),
                    start: 0,
                    end: 5,
                    segments: [TranscriptSegment(
                        text: "Recognised first line",
                        start: 0,
                        end: 5,
                        words: [TranscriptWord(
                            text: "Recognised first line",
                            start: 0,
                            end: 5
                        )]
                    )]
                ),
                TranscriptTurn(
                    speaker: .channel("Other"),
                    start: 6,
                    end: 10,
                    segments: [TranscriptSegment(
                        text: "Recognised second line",
                        start: 6,
                        end: 10,
                        words: [TranscriptWord(
                            text: "Recognised second line",
                            start: 6,
                            end: 10
                        )]
                    )]
                ),
            ]
        )
        if case .finalRun(let runID) = origin {
            let runDirectory = library.layout.runDirectory(
                meeting.id,
                runID: runID
            )
            try FileManager.default.createDirectory(
                at: runDirectory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(ProcessingRun(
                id: runID,
                meetingID: meeting.id,
                kind: .finalASR,
                engine: EngineDescriptor(name: "test", version: "1"),
                status: .finished
            )).write(to: library.layout.runMetadata(
                meeting.id,
                runID: runID
            ))
        }
        _ = try await library.appendRevision(original)
        let jobStore = try JobStore(layout: library.layout)
        let runtime = PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: PipelineCoordinator(
                library: library,
                jobStore: jobStore,
                providers: [:],
                locale: Locale(identifier: "de-DE")
            )
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            beforeTranscriptEditAppend: beforeTranscriptEditAppend,
            libraryURL: libraryRoot
        )
        await app.bootstrap()
        return Self(
            root: root,
            library: library,
            app: app,
            meeting: meeting,
            original: original,
            jobStore: jobStore
        )
    }

    func revision(
        id: RevisionID = RevisionID(),
        origin: TranscriptOrigin,
        texts: [String]
    ) -> TranscriptRevision {
        TranscriptRevision(
            id: id,
            meetingID: meeting.id,
            origin: origin,
            turns: texts.enumerated().map { index, text in
                let start = Double(index) * 10
                return TranscriptTurn(
                    speaker: .channel("Other"),
                    start: start,
                    end: start + 8,
                    segments: [TranscriptSegment(
                        text: text,
                        start: start,
                        end: start + 8,
                        words: []
                    )]
                )
            }
        )
    }

    func writeProcessingRun(
        _ runID: RunID,
        kind: ProcessingRun.Kind
    ) throws {
        let runDirectory = library.layout.runDirectory(
            meeting.id,
            runID: runID
        )
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ProcessingRun(
            id: runID,
            meetingID: meeting.id,
            kind: kind,
            engine: EngineDescriptor(name: "test", version: "1"),
            status: .finished
        )).write(to: library.layout.runMetadata(
            meeting.id,
            runID: runID
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor TranscriptEditSuspensionGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
