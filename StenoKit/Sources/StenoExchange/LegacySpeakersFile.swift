import Foundation
import StenoDomain

public struct LegacySpeakerSegment: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

public struct LegacySpeakerCluster: Equatable, Sendable {
    public let embedding: [Float]
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let segments: [LegacySpeakerSegment]
    public let reviewState: String?
    public let containsMultipleSpeakers: Bool

    init(object: [String: Any]) {
        embedding = (object["embedding"] as? [NSNumber] ?? []).map(\.floatValue)
        speechDurationSeconds = legacyDouble(object, "speech_duration_seconds") ?? 0
        segmentCount = legacyInt(object, "segment_count") ?? 0
        segments = (object["segments"] as? [[String: Any]] ?? []).map {
            LegacySpeakerSegment(
                start: legacyDouble($0, "start") ?? 0,
                end: legacyDouble($0, "end") ?? 0
            )
        }
        reviewState = legacyString(object, "review_state")
        containsMultipleSpeakers = legacyBool(object, "contains_multiple_speakers") ?? false
    }
}

public struct LegacySpeakerChannel: Equatable, Sendable {
    public let recordingType: RecordingType
    public let clusters: [String: LegacySpeakerCluster]

    init(object: [String: Any]) {
        recordingType = legacyRecordingType(legacyString(object, "recording_type"))
        let clusterObjects = object["clusters"] as? [String: [String: Any]] ?? [:]
        clusters = clusterObjects.mapValues(LegacySpeakerCluster.init(object:))
    }
}

public struct LegacyTranscriptLine: Equatable, Sendable {
    public let start: TimeInterval
    public let channel: String
    public let diarizationSpeakerID: String?
    public let originalLabel: String

    init(object: [String: Any]) {
        start = legacyDouble(object, "start") ?? 0
        channel = legacyString(object, "channel") ?? ""
        diarizationSpeakerID = legacyString(object, "diarization_speaker_id")
        originalLabel = legacyString(object, "original_label") ?? ""
    }
}

public struct LegacyTranscriptSpeakerPair: Equatable, Sendable {
    public let turn: LegacyTranscriptTurn
    public let line: LegacyTranscriptLine

    public init(turn: LegacyTranscriptTurn, line: LegacyTranscriptLine) {
        self.turn = turn
        self.line = line
    }
}

public struct LegacySpeakersFile: Equatable, Sendable {
    public let meetingID: String
    public let createdAt: Date
    public let channels: [String: LegacySpeakerChannel]
    public let transcriptLines: [LegacyTranscriptLine]?

    public static func read(from url: URL) throws -> Self {
        let object = try legacyJSONObject(from: url)
        guard let createdAt = legacyDouble(object, "created_at") else {
            throw LegacyExchangeError.invalidFormat("Missing speakers created_at")
        }
        let channelObjects = object["channels"] as? [String: [String: Any]] ?? [:]
        let lines: [LegacyTranscriptLine]?
        if let lineObjects = object["transcript_lines"] as? [[String: Any]] {
            lines = lineObjects.map(LegacyTranscriptLine.init(object:))
        } else {
            lines = nil
        }
        return Self(
            meetingID: legacyString(object, "meeting_id") ?? "",
            createdAt: Date(timeIntervalSince1970: createdAt),
            channels: channelObjects.mapValues(LegacySpeakerChannel.init(object:)),
            transcriptLines: lines
        )
    }

    public func pairTranscriptLines(
        with turns: [LegacyTranscriptTurn]
    ) throws -> [LegacyTranscriptSpeakerPair] {
        guard let transcriptLines else {
            throw LegacyExchangeError.missingTranscriptLines
        }
        guard transcriptLines.count == turns.count else {
            throw LegacyExchangeError.transcriptLineCountMismatch(
                expected: turns.count,
                actual: transcriptLines.count
            )
        }
        return zip(turns, transcriptLines).map(LegacyTranscriptSpeakerPair.init(turn:line:))
    }
}

func legacyRecordingType(_ value: String?) -> RecordingType {
    switch value {
    case "in_person": .inPerson
    case "remote": .remote
    case "imported": .imported
    default: .unknown
    }
}
