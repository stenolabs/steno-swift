import Foundation
import StenoDomain

public struct DemoInstallationIndexItem: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let itemID: String
    public let datasetVersion: String
    public let installationGenerationID: MeetingTransferGenerationID?
    public let baselineRevisionID: RevisionID
    public let baseline: DemoInstallationBaseline

    public init(
        meetingID: MeetingID,
        itemID: String,
        datasetVersion: String,
        installationGenerationID: MeetingTransferGenerationID? = nil,
        baselineRevisionID: RevisionID,
        baseline: DemoInstallationBaseline
    ) {
        self.meetingID = meetingID
        self.itemID = itemID
        self.datasetVersion = datasetVersion
        self.installationGenerationID = installationGenerationID
        self.baselineRevisionID = baselineRevisionID
        self.baseline = baseline
    }
}

public struct DemoInstallationBaseline: Codable, Equatable, Sendable {
    public static let sha256TreeV1 = "sha256-tree-v1"

    public let algorithm: String
    public let digest: String

    public init(algorithm: String = Self.sha256TreeV1, digest: String) {
        self.algorithm = algorithm
        self.digest = digest
    }
}

public struct DemoOwnedFolderClaim: Codable, Equatable, Sendable {
    public let folderID: FolderID
    public let createdAt: Date
    public let expectedName: String
    public let expectedParentFolderID: FolderID?

    public init(
        folderID: FolderID,
        createdAt: Date,
        expectedName: String,
        expectedParentFolderID: FolderID?
    ) {
        self.folderID = folderID
        self.createdAt = createdAt
        self.expectedName = expectedName
        self.expectedParentFolderID = expectedParentFolderID
    }
}

/// Reparierbarer Fortschrittscache. Besitz wird ausschließlich an der
/// Meeting-Provenienz erkannt; Ordnerbesitz nur an einem vorher validen Cache.
public struct DemoInstallationIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4
    public let schemaVersion: Int
    public let datasetID: String
    public let items: [DemoInstallationIndexItem]
    public let seederOwnedFolder: DemoOwnedFolderClaim?

    public init(
        datasetID: String,
        items: [DemoInstallationIndexItem],
        seederOwnedFolder: DemoOwnedFolderClaim?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.datasetID = datasetID
        self.items = items.sorted { $0.meetingID < $1.meetingID }
        self.seederOwnedFolder = seederOwnedFolder
    }
}
