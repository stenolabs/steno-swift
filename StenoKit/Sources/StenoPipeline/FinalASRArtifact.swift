import Foundation
import StenoDomain
import StenoTranscription

public struct FinalASRTrackResult: Codable, Equatable, Sendable {
    public let assetID: MediaAssetID
    public let assetKind: MediaAsset.Kind
    public let output: TranscriptOutput

    public init(
        assetID: MediaAssetID,
        assetKind: MediaAsset.Kind,
        output: TranscriptOutput
    ) {
        self.assetID = assetID
        self.assetKind = assetKind
        self.output = output
    }
}

public struct FinalASRArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let jobID: JobID
    public let revisionID: RevisionID
    public let tracks: [FinalASRTrackResult]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        jobID: JobID,
        revisionID: RevisionID,
        tracks: [FinalASRTrackResult]
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.revisionID = revisionID
        self.tracks = tracks
    }
}
