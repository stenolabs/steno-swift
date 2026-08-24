import Foundation
import StenoDomain
import StenoIdentity

public enum LegacyImportError: Error, Equatable, Sendable {
    case commitOutcomeUncertain(stem: String, meetingID: MeetingID)
}

extension LegacyImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commitOutcomeUncertain(let stem, let meetingID):
            "The import outcome for legacy stem \(stem) and meeting \(meetingID) "
                + "is uncertain and requires recovery before retrying."
        }
    }
}

/// Fortschritt je verarbeitetem Alt-Meeting (auch bei Duplikaten), damit
/// die Oberfläche einen langen Import nicht als eingefroren zeigt.
public struct LegacyImportProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let stem: String

    public init(completed: Int, total: Int, stem: String) {
        self.completed = completed
        self.total = total
        self.stem = stem
    }
}

public enum LegacyImportOutcome: Equatable, Sendable {
    case finished(ImportReport)
    case cancelled(ImportReport)

    public var report: ImportReport {
        switch self {
        case .finished(let report), .cancelled(let report): report
        }
    }
}

public struct ImportReport: Equatable, Sendable {
    public internal(set) var meetingsCreated = 0
    public internal(set) var audioCopied = 0
    public internal(set) var audioMissing = 0
    public internal(set) var audioRepaired = 0
    public internal(set) var revisionsCreated = 0
    public internal(set) var clustersCreated = 0
    public internal(set) var personsCreated = 0
    public internal(set) var prototypesCreated = 0
    public internal(set) var reportsCreated = 0
    public internal(set) var notesCreated = 0
    public internal(set) var duplicates: [String] = []
    public var orphans: [LegacyOrphan]
    public var pendingDeleteFindings: [URL]
    public internal(set) var warnings: [String] = []

    public init(
        orphans: [LegacyOrphan] = [],
        pendingDeleteFindings: [URL] = []
    ) {
        self.orphans = orphans
        self.pendingDeleteFindings = pendingDeleteFindings
    }
}

public struct LegacyDiarizationArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let clusters: [IdentityCluster]
    public let segmentsByClusterID: [String: [LegacySpeakerSegment]]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        clusters: [IdentityCluster],
        segmentsByClusterID: [String: [LegacySpeakerSegment]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.clusters = clusters
        self.segmentsByClusterID = segmentsByClusterID
    }
}

struct LegacyReviewDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: RunID
    let clusters: [IdentityCluster]

    init(runID: RunID, clusters: [IdentityCluster]) {
        schemaVersion = 1
        self.runID = runID
        self.clusters = clusters
    }
}
