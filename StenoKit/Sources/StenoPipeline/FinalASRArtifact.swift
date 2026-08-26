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
    /// Absolute meeting-time offset for every track's ASR times, keyed by
    /// asset ID. Tracks recorded later into the same meeting ("continue
    /// recording") keep local time zero in `output`; this map carries the
    /// shift applied when the artifact was written so downstream jobs
    /// (diarization alignment) land on the same absolute timeline.
    /// Artifacts written before append-to-meeting existed decode as nil;
    /// missing entries mean offset zero.
    public let trackOffsets: [String: TimeInterval]?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        jobID: JobID,
        revisionID: RevisionID,
        tracks: [FinalASRTrackResult],
        trackOffsets: [String: TimeInterval]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.revisionID = revisionID
        self.tracks = tracks
        self.trackOffsets = trackOffsets
    }
}
