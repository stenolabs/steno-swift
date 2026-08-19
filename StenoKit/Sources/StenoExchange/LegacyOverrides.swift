import Foundation

public struct LegacyOverrideField: Equatable, Sendable {
    public let value: LegacyJSONValue
    public let editedAt: Date?

    public init(value: LegacyJSONValue, editedAt: Date?) {
        self.value = value
        self.editedAt = editedAt
    }
}

public struct LegacyOverrides: Equatable, Sendable {
    public let fields: [String: LegacyOverrideField]

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let object = try legacyJSONObject(from: url)
        guard let fieldObjects = object["fields"] as? [String: [String: Any]] else {
            return Self(fields: [:])
        }
        var fields: [String: LegacyOverrideField] = [:]
        for (name, fieldObject) in fieldObjects {
            guard let rawValue = fieldObject["value"] else { continue }
            fields[name] = LegacyOverrideField(
                value: try LegacyJSONValue(jsonObject: rawValue),
                editedAt: legacyString(fieldObject, "edited_at")
                    .flatMap(timestampParser.date(fromISO8601:))
            )
        }
        return Self(fields: fields)
    }
}
