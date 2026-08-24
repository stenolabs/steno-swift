import Foundation
import StenoDomain
import StenoLibrary

/// Shared status and request boundary for explicit per-meeting speaker
/// separation. It follows the visible transcript back to its final-ASR source
/// and keeps imported work pinned to the local transfer generation.
public enum MeetingDiarizationRequest {
    public static func status(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID,
        modelsReady: Bool
    ) async throws -> MeetingDiarizationJobState {
        guard let context = try context(library: library, meetingID: meetingID) else {
            return .unavailable
        }
        return try await jobStore.meetingDiarizationState(
            meetingID: meetingID,
            sourceRunID: context.sourceRunID,
            importGenerationID: context.importGenerationID,
            visibleDiarizationJobID: context.visibleDiarizationJobID,
            pendingDiarizationJobID: context.pendingDiarizationJobID,
            modelsReady: modelsReady
        )
    }

    @discardableResult
    public static func request(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID,
        modelsReady: Bool
    ) async throws -> MeetingDiarizationJobState {
        guard let context = try context(library: library, meetingID: meetingID) else {
            return .unavailable
        }
        return try await jobStore.requestMeetingDiarization(
            meetingID: meetingID,
            sourceRunID: context.sourceRunID,
            importGenerationID: context.importGenerationID,
            visibleDiarizationJobID: context.visibleDiarizationJobID,
            pendingDiarizationJobID: context.pendingDiarizationJobID,
            modelsReady: modelsReady
        )
    }

    /// Makes a parked speaker-label result visible only after an explicit
    /// action. The edited revision remains stored and is never overwritten.
    @discardableResult
    public static func adoptPendingResult(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID,
        expectedCurrentRevisionID: RevisionID,
        modelsReady: Bool
    ) async throws -> MeetingDiarizationJobState {
        guard let context = try context(library: library, meetingID: meetingID),
              context.currentRevisionID == expectedCurrentRevisionID,
              let candidateID = context.pendingCandidateID
        else {
            return try await status(
                library: library,
                jobStore: jobStore,
                meetingID: meetingID,
                modelsReady: modelsReady
            )
        }
        let currentState = try await jobStore.meetingDiarizationState(
            meetingID: meetingID,
            sourceRunID: context.sourceRunID,
            importGenerationID: context.importGenerationID,
            visibleDiarizationJobID: context.visibleDiarizationJobID,
            pendingDiarizationJobID: context.pendingDiarizationJobID,
            modelsReady: modelsReady
        )
        guard currentState == .resultsPending else { return currentState }
        _ = try await library.adoptPendingRevision(
            meetingID: meetingID,
            expectedCurrentRevisionID: expectedCurrentRevisionID,
            expectedCandidateID: candidateID
        )
        return try await status(
            library: library,
            jobStore: jobStore,
            meetingID: meetingID,
            modelsReady: modelsReady
        )
    }

    private struct Context {
        let sourceRunID: RunID
        let importGenerationID: MeetingTransferGenerationID?
        let visibleDiarizationJobID: JobID?
        let pendingCandidateID: RevisionID?
        let pendingDiarizationJobID: JobID?
        let currentRevisionID: RevisionID
    }

    private struct TranscriptSource {
        let finalASRRunID: RunID
        let diarizationJobID: JobID?
    }

    private static func context(
        library: Library,
        meetingID: MeetingID
    ) throws -> Context? {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            let meeting = try library.loadMeeting(
                meetingID,
                transaction: transaction
            )
            let stateStore = MeetingTransferStateStore(layout: library.layout)
            if try stateStore.requiresFreshImportRetry(
                meetingID,
                transaction: transaction
            ) {
                throw MeetingProcessingRequestError.commitRecoveryRequired(meetingID)
            }
            guard FileManager.default.fileExists(
                atPath: library.layout.currentRevision(meetingID).path
            ) else {
                return nil
            }
            let pointer = try library.loadCurrentRevisionPointer(
                meetingID: meetingID,
                transaction: transaction
            )
            let revision = try library.loadRevision(
                pointer.currentRevisionID,
                meetingID: meetingID,
                transaction: transaction
            )
            guard hasUsableText(revision) else { return nil }
            guard let source = try transcriptSource(
                for: revision,
                library: library,
                meetingID: meetingID,
                transaction: transaction
            ) else {
                return nil
            }
            var pendingDiarizationJobID: JobID?
            if let candidateID = pointer.pendingCandidate {
                let candidate = try library.loadRevision(
                    candidateID,
                    meetingID: meetingID,
                    transaction: transaction
                )
                let candidateSource = try transcriptSource(
                    for: candidate,
                    library: library,
                    meetingID: meetingID,
                    transaction: transaction
                )
                if candidateSource?.finalASRRunID == source.finalASRRunID {
                    pendingDiarizationJobID = candidateSource?.diarizationJobID
                }
            }
            return Context(
                sourceRunID: source.finalASRRunID,
                importGenerationID: meeting.processingGenerationID,
                visibleDiarizationJobID: source.diarizationJobID,
                pendingCandidateID: pendingDiarizationJobID == nil
                    ? nil
                    : pointer.pendingCandidate,
                pendingDiarizationJobID: pendingDiarizationJobID,
                currentRevisionID: pointer.currentRevisionID
            )
        }
    }

    private static func hasUsableText(_ revision: TranscriptRevision) -> Bool {
        revision.turns.contains { turn in
            turn.segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private static func transcriptSource(
        for initialRevision: TranscriptRevision,
        library: Library,
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> TranscriptSource? {
        var revision = initialRevision
        var visited: Set<RevisionID> = []
        while true {
            guard visited.insert(revision.id).inserted else { return nil }
            switch revision.origin {
            case .userEdit(let parentID):
                revision = try library.loadRevision(
                    parentID,
                    meetingID: meetingID,
                    transaction: transaction
                )
            case .finalRun(let runID):
                return try transcriptSource(
                    for: runID,
                    expectedRevisionID: revision.id,
                    layout: library.layout,
                    meetingID: meetingID
                )
            case .liveProvisional, .legacyImport, .meetingTransfer, .demo:
                return nil
            }
        }
    }

    private static func transcriptSource(
        for runID: RunID,
        expectedRevisionID: RevisionID? = nil,
        layout: LibraryLayout,
        meetingID: MeetingID
    ) throws -> TranscriptSource? {
        var visited: Set<RunID> = []
        return try transcriptSource(
            for: runID,
            expectedRevisionID: expectedRevisionID,
            layout: layout,
            meetingID: meetingID,
            visited: &visited,
            depth: 0
        )
    }

    private static func transcriptSource(
        for runID: RunID,
        expectedRevisionID: RevisionID?,
        layout: LibraryLayout,
        meetingID: MeetingID,
        visited: inout Set<RunID>,
        depth: Int
    ) throws -> TranscriptSource? {
        // A valid provenance chain contains at most the visible diarization run
        // and its final-ASR source. More nodes mean corrupted run metadata.
        guard depth < 2, visited.insert(runID).inserted else { return nil }
        let run = try JSONDecoder().decode(
            ProcessingRun.self,
            from: Data(contentsOf: layout.runMetadata(meetingID, runID: runID))
        )
        guard run.schemaVersion == ProcessingRun.currentSchemaVersion,
              run.id == runID,
              run.meetingID == meetingID,
              run.status == .finished else {
            return nil
        }
        switch run.kind {
        case .finalASR:
            return TranscriptSource(
                finalASRRunID: runID,
                diarizationJobID: nil
            )
        case .diarization:
            let artifact = try JSONDecoder().decode(
                DiarizationArtifact.self,
                from: Data(contentsOf: layout.runDiarization(meetingID, runID: runID))
            )
            guard artifact.schemaVersion == DiarizationArtifact.currentSchemaVersion else {
                return nil
            }
            guard expectedRevisionID.map({ artifact.revisionID == $0 }) ?? true else {
                return nil
            }
            guard let source = try transcriptSource(
                for: artifact.sourceRunID,
                expectedRevisionID: nil,
                layout: layout,
                meetingID: meetingID,
                visited: &visited,
                depth: depth + 1
            ) else { return nil }
            return TranscriptSource(
                finalASRRunID: source.finalASRRunID,
                diarizationJobID: artifact.jobID
            )
        case .liveASR, .identitySuggestion, .templateRender, .export:
            return nil
        }
    }
}
