import StenoDomain
import StenoLibrary

enum TemplateRenderRequestCheckpoint: Equatable, Sendable {
    case afterPreflightValidationBeforeJobPersistence
}

typealias TemplateRenderRequestAction = @Sendable (
    TemplateRenderRequestCheckpoint
) throws -> Void

public enum TemplateRenderRequest {
    @discardableResult
    public static func enqueue(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID,
        templateID: String,
        textModelEndpointID: String? = nil,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        preflight: TemplateRenderPreflight
    ) async throws -> Job {
        try await enqueue(
            library: library,
            jobStore: jobStore,
            meetingID: meetingID,
            templateID: templateID,
            textModelEndpointID: textModelEndpointID,
            textModelEndpointSnapshot: textModelEndpointSnapshot,
            preflight: preflight,
            checkpoint: { _ in }
        )
    }

    @discardableResult
    static func enqueue(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID,
        templateID: String,
        textModelEndpointID: String? = nil,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        preflight: TemplateRenderPreflight,
        checkpoint: @escaping TemplateRenderRequestAction
    ) async throws -> Job {
        guard template(for: templateID) != nil else {
            throw PipelineError.unknownTemplate(templateID)
        }
        guard preflight.meetingID == meetingID else {
            throw TemplateRenderPreflightError.inputChanged
        }
        // Die Revision wird beim Einreihen gepinnt: das Protokoll gehört zu
        // dem Textstand, den der Nutzer vor sich hatte, nicht zu einem, der
        // während des Wartens in der Queue entstanden sein kann.
        return try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            let currentPreflight = try TemplateRenderInputAssembler.preflight(
                library: library,
                meetingID: meetingID,
                transaction: transaction
            )
            guard currentPreflight == preflight else {
                throw TemplateRenderPreflightError.inputChanged
            }
            try checkpoint(.afterPreflightValidationBeforeJobPersistence)

            let persistedPreflight = try TemplateRenderInputAssembler.preflight(
                library: library,
                meetingID: meetingID,
                transaction: transaction
            )
            guard persistedPreflight == preflight else {
                throw TemplateRenderPreflightError.inputChanged
            }
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
            let job = Job(
                kind: .templateRender,
                meetingID: meetingID,
                templateID: templateID,
                revisionID: preflight.revisionID,
                textModelEndpointID: textModelEndpointID,
                textModelEndpointSnapshot: textModelEndpointSnapshot,
                templateRenderInputFingerprint: preflight.inputFingerprint,
                importGenerationID: meeting.metadata?.transferReceipt?.importGenerationID
            )
            return try jobStore.enqueueOrExistingEquivalentJob(
                job,
                blockingStatuses: [.queued, .running],
                transaction: transaction
            )
        }
    }

    static func template(for id: String) -> Template? {
        switch id {
        case Template.meetingMinutes.id:
            .meetingMinutes
        default:
            nil
        }
    }
}
