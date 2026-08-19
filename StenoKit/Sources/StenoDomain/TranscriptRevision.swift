import Foundation

public struct TranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let words: [TranscriptWord]

    public init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        words: [TranscriptWord]
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

public enum SpeakerReference: Codable, Equatable, Hashable, Sendable {
    case channel(String)
    case cluster(runID: RunID, clusterID: String)
    case person(PersonID)
    case importedTextLabel(ImportedSpeakerTextLabel)
}

public struct TranscriptTurn: Codable, Equatable, Sendable {
    public let speaker: SpeakerReference?
    public let start: TimeInterval
    public let end: TimeInterval
    public let segments: [TranscriptSegment]

    public init(
        speaker: SpeakerReference? = nil,
        start: TimeInterval,
        end: TimeInterval,
        segments: [TranscriptSegment]
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.segments = segments
    }
}

public enum TranscriptOrigin: Codable, Equatable, Sendable {
    case liveProvisional
    case finalRun(RunID)
    case userEdit(RevisionID)
    case legacyImport
    case meetingTransfer(sourceMeetingID: MeetingID, sourceRevisionID: RevisionID?)
}

public struct TranscriptRevision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: RevisionID
    public let meetingID: MeetingID
    public let createdAt: Date
    public let origin: TranscriptOrigin
    public let turns: [TranscriptTurn]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: RevisionID = RevisionID(),
        meetingID: MeetingID,
        createdAt: Date = Date(),
        origin: TranscriptOrigin,
        turns: [TranscriptTurn]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.origin = origin
        self.turns = turns
    }
}
