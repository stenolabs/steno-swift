import Foundation
import StenoDomain

public enum LibraryError: Error, Sendable {
    case unsupportedSchemaVersion(document: URL, found: Int, supported: Int)
    case corruptDocument(original: URL, quarantined: URL)
    case missingLibraryMetadata(URL)
    case meetingNotFound(MeetingID)
    case mediaAssetNotFound(MediaAssetID, meetingID: MeetingID)
    case duplicateProvenance(key: String, existingMeetingID: MeetingID)
    case meetingTransferConflict(existingMeetingID: MeetingID)
    case documentAlreadyExists(URL)
    case invalidRevisionParent(provided: RevisionID, current: RevisionID?)
    case invalidStatusTransition(from: Job.Status, to: Job.Status)
    case duplicatePersonName(String)
    case invalidMeetingTitle
    case invalidPersonName
    case invalidPersonEmail
    case personNotFound(PersonID)
    case personAlreadyExists(PersonID)
    case speakerEvidenceNotFound(SpeakerEvidenceID)
    case cannotMergePersonIntoItself
    case folderNotFound(FolderID)
    case invalidFolderParent(FolderID)
    case invalidFolderHierarchy(String)
    case duplicateFolderName(String)
    case invalidFolderName
    case invalidPreparedMeetingImport(String)
    case invalidPreparedMediaSource(String)
    case invalidImportedMeetingProcessingState(String)
    case jobIdentityConflict(JobID)
    case transferCommitResolutionInProgress(MeetingID)
    case transferImportGenerationConflict(MeetingID)
    case abandonedMeetingImportsRequireAttention([URL])
}

public struct MeetingFolderBatchError: Error, LocalizedError, Sendable {
    public let reason: String
    public let restorationFailures: [MeetingID]

    public init(reason: String, restorationFailures: [MeetingID]) {
        self.reason = reason
        self.restorationFailures = restorationFailures
    }

    public var errorDescription: String? {
        guard !restorationFailures.isEmpty else {
            return "The meetings could not be moved. Earlier changes were restored. (\(reason))"
        }
        let ids = restorationFailures.map(\.description).joined(separator: ", ")
        return "The meetings could not be moved and restoration failed for \(ids). (\(reason))"
    }
}

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let document, let found, let supported):
            "Unsupported schema version \(found) in \(document.path); this build supports \(supported)."
        case .corruptDocument(let original, let quarantined):
            "Corrupt JSON at \(original.path) was quarantined as \(quarantined.lastPathComponent)."
        case .missingLibraryMetadata(let url):
            "Existing library directory has no metadata at \(url.path)."
        case .meetingNotFound(let id):
            "Meeting \(id) does not exist."
        case .mediaAssetNotFound(let id, let meetingID):
            "Media asset \(id) does not exist in meeting \(meetingID)."
        case .duplicateProvenance(let key, let meetingID):
            "Provenance \(key) already belongs to meeting \(meetingID)."
        case .meetingTransferConflict(let meetingID):
            "Meeting \(meetingID) already contains a different transfer version."
        case .documentAlreadyExists(let url):
            "Append-only document already exists at \(url.path)."
        case .invalidRevisionParent(let provided, let current):
            "Revision parent \(provided) is not the current revision \(current?.description ?? "none")."
        case .invalidStatusTransition(let oldStatus, let newStatus):
            "Invalid job status transition from \(oldStatus.rawValue) to \(newStatus.rawValue)."
        case .duplicatePersonName(let name):
            "A person named \(name) already exists."
        case .invalidMeetingTitle:
            "A meeting title must contain at least one non-whitespace character."
        case .invalidPersonName:
            "A person name must contain at least one non-whitespace character."
        case .invalidPersonEmail:
            "An e-mail address needs a local part, an @ and a domain, and no spaces."
        case .personNotFound(let id):
            "Person \(id) does not exist."
        case .personAlreadyExists(let id):
            "Person \(id) already exists and was not restored."
        case .speakerEvidenceNotFound(let id):
            "Voice evidence \(id) does not exist."
        case .cannotMergePersonIntoItself:
            "A person cannot be merged into themselves."
        case .folderNotFound(let id):
            "Folder \(id) does not exist."
        case .invalidFolderParent(let id):
            "Folder \(id) cannot be used as a parent."
        case .invalidFolderHierarchy(let reason):
            "Invalid folder hierarchy: \(reason)"
        case .duplicateFolderName(let name):
            "A folder named \(name) already exists."
        case .invalidFolderName:
            "A folder name must contain at least one non-whitespace character."
        case .invalidPreparedMeetingImport(let reason):
            "Invalid prepared meeting import: \(reason)."
        case .invalidPreparedMediaSource(let reason):
            "Invalid prepared media source: \(reason)."
        case .invalidImportedMeetingProcessingState(let reason):
            "Invalid imported meeting processing state: \(reason)."
        case .jobIdentityConflict(let jobID):
            "Job \(jobID) already exists with a different immutable identity."
        case .transferCommitResolutionInProgress(let meetingID):
            "Transfer commit recovery for meeting \(meetingID) is already in progress."
        case .transferImportGenerationConflict(let meetingID):
            "Meeting \(meetingID) no longer has the expected transfer import generation."
        case .abandonedMeetingImportsRequireAttention(let paths):
            "Abandoned meeting imports require attention: \(paths.map(\.path).joined(separator: ", "))."
        }
    }
}
