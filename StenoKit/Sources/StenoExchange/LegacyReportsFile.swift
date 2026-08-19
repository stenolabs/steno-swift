import Foundation

public struct LegacyReport: Equatable, Sendable {
    public let id: String
    public let templateID: String
    public let templateName: String
    public let model: String
    public let content: String
    public let createdAt: Date?

    init(object: [String: Any], timestampParser: LegacyTimestampParser) {
        id = legacyString(object, "id") ?? ""
        templateID = legacyString(object, "template_id") ?? ""
        templateName = legacyString(object, "template_name") ?? ""
        model = legacyString(object, "model") ?? ""
        content = legacyString(object, "content") ?? ""
        createdAt = legacyString(object, "created_at").flatMap(timestampParser.date(fromISO8601:))
    }
}

public struct LegacyReportsFile: Equatable, Sendable {
    public let reports: [LegacyReport]
    public let activeReport: String?

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let object = try legacyJSONObject(from: url)
        let reports = (object["reports"] as? [[String: Any]] ?? []).map {
            LegacyReport(object: $0, timestampParser: timestampParser)
        }
        return Self(reports: reports, activeReport: legacyString(object, "active_report"))
    }
}
