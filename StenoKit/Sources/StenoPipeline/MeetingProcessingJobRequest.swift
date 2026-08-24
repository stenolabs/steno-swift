import Foundation
import StenoDomain
import StenoLibrary

public enum MeetingProcessingRequestError: Error, Equatable, Sendable {
    case importedRetryRequired(MeetingID)
    case commitRecoveryRequired(MeetingID)
}

extension MeetingProcessingRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .importedRetryRequired:
            "Imported meetings must be retried with their pinned transcription language."
        case .commitRecoveryRequired:
            "This imported meeting must be recovered with a fresh package retry first."
        }
    }
}

/// Shared guard for generic Mac and iOS processing actions that would create
/// a job without an imported request's pinned generation and locale.
public enum MeetingProcessingJobRequest {
    @discardableResult
    public static func requireUnpinnedJobAllowed(
        library: Library,
        meetingID: MeetingID
    ) async throws -> MeetingTransferGenerationID? {
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
            if meeting.metadata?.transferReceipt?.importGenerationID != nil {
                throw MeetingProcessingRequestError.importedRetryRequired(meetingID)
            }
            return meeting.processingGenerationID
        }
    }
}
