import Foundation
import StenoDomain

public struct DiarizationRunSegment: Codable, Equatable, Sendable {
    public let clusterID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(clusterID: String, start: TimeInterval, end: TimeInterval) {
        self.clusterID = clusterID
        self.start = start
        self.end = end
    }
}

public struct DiarizationClusterResult: Codable, Equatable, Sendable {
    public let clusterID: String
    public let embedding: [Float]
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int

    public init(
        clusterID: String,
        embedding: [Float],
        speechDurationSeconds: TimeInterval,
        segmentCount: Int
    ) {
        self.clusterID = clusterID
        self.embedding = embedding
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
    }
}

public struct DiarizationTrackResult: Codable, Equatable, Sendable {
    public let assetID: MediaAssetID
    public let assetKind: MediaAsset.Kind
    public let engine: EngineDescriptor
    public let segments: [DiarizationRunSegment]
    public let clusters: [DiarizationClusterResult]

    public init(
        assetID: MediaAssetID,
        assetKind: MediaAsset.Kind,
        engine: EngineDescriptor,
        segments: [DiarizationRunSegment],
        clusters: [DiarizationClusterResult]
    ) {
        self.assetID = assetID
        self.assetKind = assetKind
        self.engine = engine
        self.segments = segments
        self.clusters = clusters
    }
}

public struct DiarizationArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let jobID: JobID
    public let sourceRunID: RunID
    public let revisionID: RevisionID
    public let tracks: [DiarizationTrackResult]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        jobID: JobID,
        sourceRunID: RunID,
        revisionID: RevisionID,
        tracks: [DiarizationTrackResult]
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.sourceRunID = sourceRunID
        self.revisionID = revisionID
        self.tracks = tracks
    }
}
