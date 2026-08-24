import Foundation
import StenoDomain
import StenoLibrary

enum TranscriptCorrectionCopy {
    static let actionLabel: LocalizedStringResource = "Correct line"
    static let actionHint: LocalizedStringResource =
        "Opens an editor for this transcript line."
    static let sheetTitle: LocalizedStringResource = "Correct transcript line"
    static let revisionNote: LocalizedStringResource =
        "The recognised text remains available as an earlier revision."
    static let cancelTitle: LocalizedStringResource = "Cancel"
    static let saveTitle: LocalizedStringResource = "Save"
}

enum TranscriptCorrectionBlockReason: Equatable {
    case recording
    case actionInFlight
    case processing

    var message: LocalizedStringResource {
        switch self {
        case .recording:
            "Transcript correction is unavailable while recording."
        case .actionInFlight:
            "Another transcript action is still finishing."
        case .processing:
            "Wait for transcription or speaker separation to finish."
        }
    }
}

enum TranscriptCorrectionAvailability: Equatable {
    case available
    case blocked(TranscriptCorrectionBlockReason)

    var isAvailable: Bool { self == .available }

    var blockReason: TranscriptCorrectionBlockReason? {
        guard case .blocked(let reason) = self else { return nil }
        return reason
    }
}

enum TranscriptCorrectionPolicy {
    static func availability(
        meetingStatus: Meeting.Status?,
        recordingIsActive: Bool,
        actionIsInFlight: Bool,
        jobs: [Job]
    ) -> TranscriptCorrectionAvailability {
        if recordingIsActive || meetingStatus == .recording {
            return .blocked(.recording)
        }
        if actionIsInFlight {
            return .blocked(.actionInFlight)
        }
        if jobs.contains(where: { job in
            (job.kind == .finalASR || job.kind == .diarization)
                && (job.status == .queued || job.status == .running)
        }) {
            return .blocked(.processing)
        }
        return .available
    }
}

struct TranscriptTurnMatch: Equatable, Identifiable {
    let turnIndex: Int
    let turn: TranscriptTurn

    var id: Int { turnIndex }
}

enum TranscriptTurnPresentation {
    static func matches(
        in revision: TranscriptRevision,
        query: String
    ) -> [TranscriptTurnMatch] {
        TranscriptSearch.matchingTurnIndices(in: revision, query: query).map {
            TranscriptTurnMatch(turnIndex: $0, turn: revision.turns[$0])
        }
    }

    static func text(of turn: TranscriptTurn) -> String {
        turn.segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TranscriptCorrectionTarget: Equatable, Identifiable {
    struct ID: Hashable {
        let revisionID: RevisionID
        let turnIndex: Int
    }

    let meetingID: MeetingID
    let revision: TranscriptRevision
    let turnIndex: Int
    let initialDraft: String

    var id: ID { ID(revisionID: revision.id, turnIndex: turnIndex) }

    init?(
        meetingID: MeetingID,
        revision: TranscriptRevision,
        turnIndex: Int
    ) {
        guard revision.meetingID == meetingID,
              revision.turns.indices.contains(turnIndex)
        else { return nil }
        self.meetingID = meetingID
        self.revision = revision
        self.turnIndex = turnIndex
        initialDraft = TranscriptTurnPresentation.text(
            of: revision.turns[turnIndex]
        )
    }
}

struct MeetingTranscriptPointerSnapshot: Equatable, Sendable {
    enum PendingClassification: Equatable, Sendable {
        case none
        case transcription(TranscriptRevision)
        case diarization(RevisionID)
    }

    let meetingID: MeetingID
    let pointer: CurrentRevisionPointer
    let diarizationState: MeetingDiarizationJobState
    let pendingClassification: PendingClassification

    init?(
        meetingID: MeetingID,
        pointer: CurrentRevisionPointer,
        loadedPendingRevision: TranscriptRevision?,
        diarizationState: MeetingDiarizationJobState
    ) {
        let classification: PendingClassification
        switch (
            pointer.pendingCandidate,
            loadedPendingRevision,
            diarizationState
        ) {
        case (nil, nil, .resultsPending):
            return nil
        case (nil, nil, _):
            classification = .none
        case (let candidateID?, let candidate?, .resultsPending):
            guard candidate.id == candidateID,
                  candidate.meetingID == meetingID
            else { return nil }
            classification = .diarization(candidateID)
        case (let candidateID?, let candidate?, _):
            guard candidate.id == candidateID,
                  candidate.meetingID == meetingID
            else { return nil }
            classification = .transcription(candidate)
        case (nil, .some, _), (.some, nil, _):
            return nil
        }
        self.meetingID = meetingID
        self.pointer = pointer
        self.diarizationState = diarizationState
        pendingClassification = classification
    }

    var visiblePendingRevision: TranscriptRevision? {
        guard case .transcription(let revision) = pendingClassification else {
            return nil
        }
        return revision
    }

    func matches(
        loadedRevision: TranscriptRevision?,
        loadedDiarizationState: MeetingDiarizationJobState,
        freshPointer: CurrentRevisionPointer?
    ) -> Bool {
        loadedRevision?.meetingID == meetingID
            && loadedRevision?.id == pointer.currentRevisionID
            && loadedDiarizationState == diarizationState
            && freshPointer == pointer
    }
}

struct MeetingTranscriptPublicationGate {
    struct LoadToken: Equatable {
        fileprivate let viewIdentity:
            ViewIdentityGeneration<MeetingID>.Token
        fileprivate let generation: UInt64
    }

    struct SheetSaveToken: Equatable {
        fileprivate let viewIdentity:
            ViewIdentityGeneration<MeetingID>.Token
        fileprivate let generation: UInt64
        fileprivate let meetingID: MeetingID
        fileprivate let parentRevisionID: RevisionID
    }

    private var viewIdentity: ViewIdentityGeneration<MeetingID>.Token?
    private var generation: UInt64 = 0

    mutating func reset(
        for viewIdentity: ViewIdentityGeneration<MeetingID>.Token
    ) {
        generation &+= 1
        self.viewIdentity = viewIdentity
    }

    mutating func beginLoad(
        for viewIdentity: ViewIdentityGeneration<MeetingID>.Token
    ) -> LoadToken? {
        guard self.viewIdentity == viewIdentity else { return nil }
        generation &+= 1
        return LoadToken(
            viewIdentity: viewIdentity,
            generation: generation
        )
    }

    func sheetSaveToken(
        for target: TranscriptCorrectionTarget,
        viewIdentity: ViewIdentityGeneration<MeetingID>.Token
    ) -> SheetSaveToken? {
        guard self.viewIdentity == viewIdentity,
              viewIdentity.value == target.meetingID
        else { return nil }
        return SheetSaveToken(
            viewIdentity: viewIdentity,
            generation: generation,
            meetingID: target.meetingID,
            parentRevisionID: target.revision.id
        )
    }

    func acceptsLoadIdentity(
        _ token: LoadToken,
        identity: ViewIdentityGeneration<MeetingID>,
        currentMeetingID: MeetingID
    ) -> Bool {
        viewIdentity == token.viewIdentity
            && token.generation == generation
            && identity.accepts(
                token.viewIdentity,
                currentValue: currentMeetingID
            )
    }

    func accepts(
        _ token: LoadToken,
        loadedRevision: TranscriptRevision?,
        loadedDiarizationState: MeetingDiarizationJobState,
        loadedPointerSnapshot: MeetingTranscriptPointerSnapshot?,
        freshPointer: CurrentRevisionPointer?,
        identity: ViewIdentityGeneration<MeetingID>,
        currentMeetingID: MeetingID
    ) -> Bool {
        guard acceptsLoadIdentity(
            token,
            identity: identity,
            currentMeetingID: currentMeetingID
        ) else { return false }
        if let loadedPointerSnapshot {
            return loadedPointerSnapshot.meetingID == currentMeetingID
                && loadedPointerSnapshot.matches(
                loadedRevision: loadedRevision,
                loadedDiarizationState: loadedDiarizationState,
                freshPointer: freshPointer
            )
        }
        return loadedRevision == nil
            && freshPointer == nil
            && loadedDiarizationState != .resultsPending
    }

    func acceptsSheetCallback(
        _ token: SheetSaveToken,
        identity: ViewIdentityGeneration<MeetingID>,
        currentMeetingID: MeetingID
    ) -> Bool {
        viewIdentity == token.viewIdentity
            && token.generation == generation
            && token.meetingID == currentMeetingID
            && identity.accepts(
                token.viewIdentity,
                currentValue: currentMeetingID
            )
    }

    mutating func acceptsSavedRevision(
        _ revision: TranscriptRevision,
        for token: SheetSaveToken,
        identity: ViewIdentityGeneration<MeetingID>,
        currentMeetingID: MeetingID
    ) -> Bool {
        guard acceptsSheetCallback(
            token,
            identity: identity,
            currentMeetingID: currentMeetingID
        ),
        revision.meetingID == token.meetingID,
        revision.origin == .userEdit(token.parentRevisionID)
        else { return false }
        generation &+= 1
        return true
    }
}

struct TranscriptCorrectionSession: Identifiable {
    let target: TranscriptCorrectionTarget
    let saveToken: MeetingTranscriptPublicationGate.SheetSaveToken

    var id: TranscriptCorrectionTarget.ID { target.id }
}

enum TranscriptCorrectionSheetEffect: Equatable {
    case stayOpen
    case reloadAfterConflict(currentRevision: TranscriptRevision?)
    case saved(updatedVisibleRevision: TranscriptRevision)
}

struct TranscriptCorrectionSheetState: Equatable {
    let target: TranscriptCorrectionTarget
    var draft: String
    var isSaving = false
    var error: TranscriptCorrectionError?

    init(target: TranscriptCorrectionTarget) {
        self.target = target
        draft = target.initialDraft
    }

    var canSave: Bool {
        !isSaving
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func beginSave() -> Bool {
        guard canSave else { return false }
        isSaving = true
        error = nil
        return true
    }

    mutating func receive(
        _ result: TranscriptCorrectionSaveResult
    ) -> TranscriptCorrectionSheetEffect {
        isSaving = false
        switch result {
        case .saved(let revision):
            error = nil
            return .saved(updatedVisibleRevision: revision)
        case .unchanged:
            error = .unchangedText
            return .stayOpen
        case .failed(let failure):
            error = failure
            if case .revisionConflict(let currentRevision) = failure {
                return .reloadAfterConflict(currentRevision: currentRevision)
            }
            return .stayOpen
        }
    }
}

extension TranscriptCorrectionError {
    var title: LocalizedStringResource {
        switch self {
        case .revisionConflict:
            "Transcript changed"
        case .unchangedText:
            "No changes to save"
        default:
            "Correction not saved"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .libraryUnavailable:
            "The library is not ready yet. Try again when the meeting has loaded."
        case .recordingInProgress:
            "Transcript correction is unavailable while recording."
        case .editInFlight:
            "This meeting is already saving another transcript correction."
        case .conflictingActionInFlight:
            "Another library action is still finishing. Try again in a moment."
        case .processingInFlight:
            "Wait for transcription or speaker separation to finish, then try again."
        case .wrongMeeting:
            "This correction no longer belongs to the open meeting."
        case .emptyText:
            "A transcript line cannot be empty."
        case .turnOutOfRange:
            "This line no longer exists in the current transcript."
        case .revisionConflict:
            "This transcript changed while you were editing. Steno did not overwrite it. The current version has been reloaded and your draft remains here. Copy it if needed, then cancel and reopen the current line before saving."
        case .persistenceFailure:
            "The correction could not be stored. Your draft remains open so you can try again."
        case .unchangedText:
            "Change the text or cancel the correction."
        }
    }
}

struct PendingTranscriptPresentation: Equatable {
    let expectedCurrentRevisionID: RevisionID
    let expectedCandidateID: RevisionID

    let title: LocalizedStringResource = "A newer transcription is ready."
    let message: LocalizedStringResource = "Your correction is shown instead."
    let actionTitle: LocalizedStringResource = "Use the new one"
    let actionHint: LocalizedStringResource =
        "Your correction remains available as an earlier revision."

    static func make(
        currentRevision: TranscriptRevision,
        pendingRevision: TranscriptRevision?,
        diarizationState: MeetingDiarizationJobState
    ) -> Self? {
        guard let pendingRevision,
              pendingRevision.meetingID == currentRevision.meetingID,
              diarizationState != .resultsPending
        else { return nil }
        return Self(
            expectedCurrentRevisionID: currentRevision.id,
            expectedCandidateID: pendingRevision.id
        )
    }
}

struct PendingTranscriptAdoptionPresentation: Equatable {
    let message: LocalizedStringResource

    static func make(
        _ result: PendingTranscriptAdoptionResult
    ) -> Self? {
        let message: LocalizedStringResource
        switch result {
        case .adopted:
            return nil
        case .staleRevisionPair:
            message = "The shown transcription changed before it could be selected. Nothing was replaced. The current versions have been reloaded."
        case .diarizationCandidate:
            message = "This is a speaker-separation result. Use “Use speaker labels” instead."
        case .blocked(.recordingInProgress):
            message = "Stop the recording before switching transcript revisions."
        case .blocked(.editInFlight):
            message = "Wait for the transcript correction to finish, then try again."
        case .blocked(.conflictingActionInFlight):
            message = "Another library action is still finishing. Try again in a moment."
        case .blocked(.processingInFlight):
            message = "Wait for transcription or speaker separation to finish, then try again."
        case .failed(.libraryUnavailable):
            message = "The library is not ready yet. Try again when the meeting has loaded."
        case .failed(.persistenceFailure):
            message = "The newer transcription could not be selected because of a storage error. Nothing was replaced."
        }
        return Self(message: message)
    }
}
