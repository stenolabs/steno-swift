import OSLog
import StenoDomain
import StenoLibrary
import StenoPipeline

enum TranscriptCorrectionSaveResult: Equatable, Sendable {
    case saved(TranscriptRevision)
    case unchanged
    case failed(TranscriptCorrectionError)
}

enum TranscriptCorrectionError: Error, Equatable, Sendable {
    case libraryUnavailable
    case recordingInProgress
    case editInFlight
    case conflictingActionInFlight
    case processingInFlight
    case wrongMeeting
    case emptyText
    case turnOutOfRange
    case unchangedText
    case revisionConflict(currentRevision: TranscriptRevision?)
    case persistenceFailure
}

enum PendingTranscriptAdoptionBlockReason: Equatable, Sendable {
    case recordingInProgress
    case editInFlight
    case conflictingActionInFlight
    case processingInFlight
}

enum PendingTranscriptAdoptionFailure: Equatable, Sendable {
    case libraryUnavailable
    case persistenceFailure
}

enum PendingTranscriptAdoptionResult: Equatable, Sendable {
    case adopted
    case staleRevisionPair
    case diarizationCandidate
    case blocked(PendingTranscriptAdoptionBlockReason)
    case failed(PendingTranscriptAdoptionFailure)
}

private let transcriptCorrectionLogger = Logger(
    subsystem: "org.steno.Steno",
    category: "TranscriptCorrection"
)

@MainActor
extension AppModel {
    /// Appends one correction against the exact revision displayed by this
    /// window. `Library.appendRevision` verifies that this revision is still
    /// current, so a concurrent edit or pipeline result can never be silently
    /// overwritten or used as an implicit rebase target.
    func saveTranscriptEdit(
        meetingID: MeetingID,
        revision: TranscriptRevision,
        turnIndex: Int,
        text: String
    ) async -> TranscriptCorrectionSaveResult {
        guard revision.meetingID == meetingID else {
            return .failed(.wrongMeeting)
        }
        guard let runtime else {
            return .failed(.libraryUnavailable)
        }
        guard !recording.isActive else {
            return .failed(.recordingInProgress)
        }

        let edited: TranscriptRevision
        do {
            edited = try TranscriptEdit.replacingText(
                in: revision,
                turnIndex: turnIndex,
                with: text
            )
        } catch TranscriptEdit.Failure.unchanged {
            return .unchanged
        } catch TranscriptEdit.Failure.emptyText {
            return .failed(.emptyText)
        } catch TranscriptEdit.Failure.turnOutOfRange {
            return .failed(.turnOutOfRange)
        } catch {
            transcriptCorrectionLogger.error(
                "Unexpected transcript edit preparation failure: \(String(describing: error), privacy: .private)"
            )
            return .failed(.persistenceFailure)
        }

        guard transcriptEditsInFlight.insert(meetingID).inserted else {
            return .failed(.editInFlight)
        }
        defer { transcriptEditsInFlight.remove(meetingID) }

        guard let operation = beginLibraryOperation() else {
            return .failed(.conflictingActionInFlight)
        }
        defer { endFolderOperation(operation) }

        do {
            let jobs = try await runtime.jobStore.list()
            guard !Self.hasRevisionProducingJobInFlight(
                for: meetingID,
                jobs: jobs
            ) else {
                return .failed(.processingInFlight)
            }
            await beforeTranscriptEditAppend()
            _ = try await runtime.library.appendRevision(edited)
            return .saved(edited)
        } catch LibraryError.invalidRevisionParent {
            let current = try? await runtime.library.loadCurrentRevision(
                meetingID: meetingID
            )
            return .failed(.revisionConflict(currentRevision: current))
        } catch {
            transcriptCorrectionLogger.error(
                "Transcript correction persistence failed: \(String(describing: error), privacy: .private)"
            )
            return .failed(.persistenceFailure)
        }
    }

    /// Loads the exact current/candidate pointer and classifies its candidate.
    /// Speaker-label results remain identified even though they are hidden
    /// from the generic newer-transcription banner.
    func pendingTranscriptSnapshot(
        for meetingID: MeetingID
    ) async -> MeetingTranscriptPointerSnapshot? {
        guard let runtime else { return nil }
        do {
            let pointerBefore = try await runtime.library
                .loadCurrentRevisionPointer(meetingID: meetingID)
            let candidate: TranscriptRevision?
            if let candidateID = pointerBefore.pendingCandidate {
                candidate = try await runtime.library.loadRevision(
                    candidateID,
                    meetingID: meetingID
                )
            } else {
                candidate = nil
            }
            let diarizationState = try await MeetingDiarizationRequest.status(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady:
                    diarizationModels.isReady(for: language.locale) == true
            )
            let pointerAfter = try await runtime.library
                .loadCurrentRevisionPointer(meetingID: meetingID)
            guard pointerAfter == pointerBefore else { return nil }
            return MeetingTranscriptPointerSnapshot(
                meetingID: meetingID,
                pointer: pointerBefore,
                loadedPendingRevision: candidate,
                diarizationState: diarizationState
            )
        } catch {
            transcriptCorrectionLogger.error(
                "Pending transcript classification failed: \(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    /// The automatic result parked behind a user correction. Loading it is
    /// read-only; showing it never adopts it.
    func pendingTranscript(
        for meetingID: MeetingID
    ) async -> TranscriptRevision? {
        await pendingTranscriptSnapshot(for: meetingID)?.visiblePendingRevision
    }

    /// Adopts only the exact current/candidate pair shown by this window.
    /// Both IDs are required so an older iPad window cannot accept a newer
    /// candidate or replace a newer correction it has never displayed.
    func adoptPendingTranscript(
        meetingID: MeetingID,
        expectedCurrentRevisionID: RevisionID,
        expectedCandidateID: RevisionID
    ) async -> PendingTranscriptAdoptionResult {
        guard let runtime else {
            return .failed(.libraryUnavailable)
        }
        guard !recording.isActive else {
            return .blocked(.recordingInProgress)
        }
        guard !transcriptEditsInFlight.contains(meetingID) else {
            return .blocked(.editInFlight)
        }
        guard let operation = beginLibraryOperation() else {
            return .blocked(.conflictingActionInFlight)
        }
        defer { endFolderOperation(operation) }

        do {
            let jobs = try await runtime.jobStore.list()
            guard !Self.hasRevisionProducingJobInFlight(
                for: meetingID,
                jobs: jobs
            ) else { return .blocked(.processingInFlight) }
            let pointer = try await runtime.library.loadCurrentRevisionPointer(
                meetingID: meetingID
            )
            guard pointer.currentRevisionID == expectedCurrentRevisionID,
                  pointer.pendingCandidate == expectedCandidateID
            else { return .staleRevisionPair }
            let diarizationState = try await MeetingDiarizationRequest.status(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady:
                    diarizationModels.isReady(for: language.locale) == true
            )
            guard diarizationState != .resultsPending else {
                return .diarizationCandidate
            }
            guard try await runtime.library.adoptPendingRevision(
                meetingID: meetingID,
                expectedCurrentRevisionID: expectedCurrentRevisionID,
                expectedCandidateID: expectedCandidateID
            ) != nil else {
                return .staleRevisionPair
            }
            return .adopted
        } catch {
            transcriptCorrectionLogger.error(
                "Pending transcript adoption failed: \(String(describing: error), privacy: .private)"
            )
            return .failed(.persistenceFailure)
        }
    }

    private static func hasRevisionProducingJobInFlight(
        for meetingID: MeetingID,
        jobs: [Job]
    ) -> Bool {
        jobs.contains { job in
            job.meetingID == meetingID
                && (job.kind == .finalASR || job.kind == .diarization)
                && (job.status == .queued || job.status == .running)
        }
    }
}
