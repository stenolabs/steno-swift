import Foundation

public struct LegacySummarySessionInfo: Equatable, Sendable {
    public let name: String
    public let audioFile: String?
    public let processedAt: Date?
    public let durationSeconds: TimeInterval?
    public let language: String?
    public let configuredLanguage: String?
    public let detectedLanguage: String?
    public let reprocessable: Bool?
    public let updatedAt: Date?

    init(object: [String: Any], timestampParser: LegacyTimestampParser) {
        name = legacyString(object, "name") ?? ""
        audioFile = legacyString(object, "audio_file")
        processedAt = legacyString(object, "processed_at").flatMap(timestampParser.date(fromISO8601:))
        durationSeconds = legacyDouble(object, "duration_seconds")
        language = legacyString(object, "language")
        configuredLanguage = legacyString(object, "configured_language")
        detectedLanguage = legacyString(object, "detected_language")
        reprocessable = legacyBool(object, "reprocessable")
        updatedAt = legacyString(object, "updated_at").flatMap(timestampParser.date(fromISO8601:))
    }
}

public struct LegacyDiscussionArea: Equatable, Sendable {
    public let title: String
    public let analysis: String

    public init(title: String, analysis: String) {
        self.title = title
        self.analysis = analysis
    }
}

public struct LegacySummaryJSON: Equatable, Sendable {
    public let sessionInfo: LegacySummarySessionInfo
    public let summary: String
    public let participants: [String]
    public let discussionAreas: [LegacyDiscussionArea]
    public let keyPoints: [String]
    public let actionItems: [String]
    public let transcript: String
    public let isDiarised: Bool
    public let diarisedText: String
    public let userNotes: String?
    public let folders: [String]

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let object = try legacyJSONObject(from: url)
        guard let sessionObject = object["session_info"] as? [String: Any] else {
            throw LegacyExchangeError.invalidFormat("Missing session_info")
        }
        let areas = (object["discussion_areas"] as? [[String: Any]] ?? []).map {
            LegacyDiscussionArea(
                title: legacyString($0, "title") ?? "",
                analysis: legacyString($0, "analysis") ?? ""
            )
        }
        return Self(
            sessionInfo: LegacySummarySessionInfo(
                object: sessionObject,
                timestampParser: timestampParser
            ),
            summary: legacyString(object, "summary") ?? "",
            participants: legacyStringArray(object["participants"]),
            discussionAreas: areas,
            keyPoints: legacyStringArray(object["key_points"]),
            actionItems: legacyStringArray(object["action_items"]),
            transcript: legacyString(object, "transcript") ?? "",
            isDiarised: legacyBool(object, "is_diarised") ?? false,
            diarisedText: legacyString(object, "diarised_text") ?? "",
            userNotes: legacyString(object, "user_notes"),
            folders: legacyStringArray(object["folders"])
        )
    }
}
