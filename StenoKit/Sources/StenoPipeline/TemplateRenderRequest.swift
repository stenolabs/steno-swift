import Foundation
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
                importGenerationID: meeting.processingGenerationID
            )
            return try jobStore.enqueueOrExistingEquivalentJob(
                job,
                blockingStatuses: [.queued, .running],
                transaction: transaction
            )
        }
    }

    /// Resolves the renderable definition for a template id: locked
    /// built-ins (with a user override applied where one exists) and
    /// user-defined custom templates from the catalog. The catalog lives in
    /// UserDefaults so both enqueue-time validation here and run-time
    /// resolution in the coordinator see the same definitions without any
    public static func template(
        for id: String,
        defaults: UserDefaults = .standard
    ) -> Template? {
        TemplateCatalogStore(defaults: defaults).load().resolve(id: id)
    }

    /// Report-run template precedence for a single meeting:
    /// explicit per-run picker choice > meeting pin (recording-time
    /// choice) > catalog default > Meeting Minutes. A pinned id that no
    /// longer resolves (deleted custom template) falls through to the
    /// catalog default instead of failing the run.
    public static func resolveReportTemplateID(
        explicit: String?,
        pinned: String?,
        defaults: UserDefaults = .standard
    ) -> String {
        let catalog = TemplateCatalogStore(defaults: defaults).load()
        if let explicit, catalog.resolve(id: explicit) != nil {
            return explicit
        }
        if let pinned, catalog.resolve(id: pinned) != nil {
            return pinned
        }
        return catalog.resolvedDefault().id
    }
}

/// One-shot per-recording template choice for the recording dock:
///
/// - `choose` records the dock selection (nil = global default flow,
///   byte-identical behavior to before pinning existed).
/// - A NEW-meeting recording carries the choice onto the created meeting;
///   a mid-recording switch re-pins live via another `choose`.
/// - Continue/append recordings adopt the note's EXISTING pin for display
///   but never override it (`choose` becomes a no-op).
/// - `resetAfterStop` implements the one-shot semantics: the choice
///   applies to exactly one recording, then falls back to the default.
public struct RecordingTemplateChoice: Equatable, Sendable {
    public private(set) var pinnedTemplateID: String?
    public private(set) var continuesExistingMeeting = false

    public init() {}

    /// Dock selection; ignored entirely for continue/append recordings.
    public mutating func choose(_ templateID: String?) {
        guard !continuesExistingMeeting else { return }
        pinnedTemplateID = templateID
    }

    /// Start of a fresh recording: any earlier leftover choice applies.
    public mutating func beginNewMeeting() {
        continuesExistingMeeting = false
    }

    /// Continue/append: show the note's existing pin, never override it.
    public mutating func beginExistingMeeting(pinnedTemplateID: String?) {
        continuesExistingMeeting = true
        self.pinnedTemplateID = pinnedTemplateID
    }

    /// Stop (or abort): the choice was consumed by this one recording.
    public mutating func resetAfterStop() {
        pinnedTemplateID = nil
        continuesExistingMeeting = false
    }
}
