import Foundation
import StenoDomain

public struct IdentityClusterResolution: Codable, Equatable, Sendable {
    public let channel: String
    public let sourceClusterID: String
    public let primaryClusterID: String

    public init(
        channel: String,
        sourceClusterID: String,
        primaryClusterID: String
    ) {
        self.channel = channel
        self.sourceClusterID = sourceClusterID
        self.primaryClusterID = primaryClusterID
    }
}

public struct IdentitySuggestionArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let jobID: JobID
    public let sourceRunID: RunID
    public let clusterResolutions: [IdentityClusterResolution]
    public let identityEvidenceFingerprint: String
    public let suggestions: [ClusterSuggestion]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        jobID: JobID,
        sourceRunID: RunID,
        clusterResolutions: [IdentityClusterResolution],
        identityEvidenceFingerprint: String,
        suggestions: [ClusterSuggestion]
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.sourceRunID = sourceRunID
        self.clusterResolutions = clusterResolutions
        self.identityEvidenceFingerprint = identityEvidenceFingerprint
        self.suggestions = suggestions
    }
}
