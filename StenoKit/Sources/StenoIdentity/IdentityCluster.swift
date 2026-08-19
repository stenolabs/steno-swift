import Foundation
import StenoDomain

public struct IdentityCluster: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let runID: RunID
    public let channel: String
    public let clusterID: String
    public let recordingType: RecordingType
    public let embedding: [Float]
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let mergedFrom: [String]
    public var containsMultipleSpeakers: Bool
    public var reviewState: ReviewState
    public let isSelf: Bool

    public enum ReviewState: Codable, Equatable, Sendable {
        case unreviewed
        case generic
        case multiple
        case confirmed(PersonID)
        case stale(PersonID)
    }

    public init(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        clusterID: String,
        recordingType: RecordingType,
        embedding: [Float],
        speechDurationSeconds: TimeInterval,
        segmentCount: Int,
        mergedFrom: [String] = [],
        containsMultipleSpeakers: Bool = false,
        reviewState: ReviewState = .unreviewed,
        isSelf: Bool = false
    ) {
        self.meetingID = meetingID
        self.runID = runID
        self.channel = channel
        self.clusterID = clusterID
        self.recordingType = recordingType
        self.embedding = embedding
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
        self.mergedFrom = mergedFrom
        self.containsMultipleSpeakers = containsMultipleSpeakers
        self.reviewState = reviewState
        self.isSelf = isSelf
    }
}
