import Foundation

public struct LegacyFolder: Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let createdAt: Date?
    public let order: Int
    public let icon: String?

    init(object: [String: Any], timestampParser: LegacyTimestampParser) {
        id = legacyString(object, "id") ?? ""
        name = legacyString(object, "name") ?? ""
        color = legacyString(object, "color") ?? ""
        createdAt = legacyString(object, "created_at").flatMap(timestampParser.date(fromISO8601:))
        order = legacyInt(object, "order") ?? 0
        icon = legacyString(object, "icon")
    }
}

public struct LegacyFolders: Equatable, Sendable {
    public let folders: [LegacyFolder]

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let object = try legacyJSONObject(from: url)
        let folders = (object["folders"] as? [[String: Any]] ?? []).map {
            LegacyFolder(object: $0, timestampParser: timestampParser)
        }
        return Self(folders: folders)
    }
}
