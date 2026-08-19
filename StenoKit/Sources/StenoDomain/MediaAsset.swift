import Foundation

public struct MediaAsset: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: MediaAssetID
    public let meetingID: MeetingID
    public let kind: Kind
    public let sampleRate: Double
    public let duration: TimeInterval
    public let provenanceKey: String
    public let fileName: String
    public let conversion: Conversion?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: MediaAssetID = MediaAssetID(),
        meetingID: MeetingID,
        kind: Kind,
        sampleRate: Double,
        duration: TimeInterval,
        provenanceKey: String,
        fileName: String,
        conversion: Conversion? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.sampleRate = sampleRate
        self.duration = duration
        self.provenanceKey = provenanceKey
        self.fileName = fileName
        self.conversion = conversion
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        case micTrack
        case systemTrack
        case imported
    }

    public enum Conversion: String, Codable, Equatable, Sendable {
        case webMOpusRepackagedToCAF
    }
}
