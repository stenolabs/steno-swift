import Foundation
import StenoDomain

public enum DemoLibraryError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unexpectedDatasetID(String)
    case emptyDatasetVersion
    case invalidMeetingCount(Int)
    case duplicateIdentifier(kind: String, value: String)
    case invalidUTCDate(String)
    case unknownDemoItemID(String)
    case unexpectedFixedMeetingID(itemID: String, actual: MeetingID)
    case unexpectedFixedUTCDate(itemID: String, field: String, actual: String)
    case invalidDemoTitle(String)
    case invalidSampleRate(MediaAssetID)
    case invalidDuration(MediaAssetID)
    case invalidGeneratorProvenance
    case invalidResourceDescriptor(String)
    case invalidMeetingBlueprint(itemID: String, reason: String)
    case unreferencedResource(id: String)
    case invalidUTF8(resourceID: String)
    case invalidSHA256(id: String)
    case unknownResourceID(String)
    case unexpectedResourceKind(id: String, expected: DemoResourceKind, actual: DemoResourceKind)
    case invalidResourcePath(String)
    case resourceEscapesBundle(String)
    case symbolicLink(String)
    case invalidBundleRoot(path: String)
    case invalidResourceDirectoryComponent(String)
    case invalidResourceFileType(id: String, path: String)
    case missingResource(id: String, path: String)
    case resourceReadFailed(id: String, path: String)
    case wrongByteCount(id: String, expected: Int64, actual: Int64)
    case wrongSHA256(id: String)
    case invalidTranscript(resourceID: String)
    case unsupportedTranscriptSchemaVersion(resourceID: String, actual: Int)
    case unexpectedTranscriptCreatedAt(resourceID: String)
    case transcriptMismatch(resourceID: String, field: String)
    case manifestReadFailed(path: String)
    case invalidManifest(path: String)
    case bundledDatasetMissing
    case conflictingMeeting(MeetingID)
    case lifecycleOperationUnavailable
    case commitOutcomeUncertain(MeetingID)
    case outdatedMeeting(MeetingID, installedVersion: String)
}
