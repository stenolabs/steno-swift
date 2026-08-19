import Foundation

public enum LegacyFrontmatterValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case null
    case array([LegacyJSONValue])
}

public struct LegacySummarySection: Equatable, Sendable {
    public let title: String
    public let content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

public struct LegacySummaryTopic: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct LegacySummaryBody: Equatable, Sendable {
    public let sections: [LegacySummarySection]
    public let summary: String?
    public let keyTopics: [LegacySummaryTopic]
    public let keyPoints: [String]
    public let actionItems: [String]
    public let participants: [String]
    public let transcript: String?
    public let userNotes: String?

    public init(sections: [LegacySummarySection]) {
        self.sections = sections
        let byTitle = sections.reduce(into: [String: String]()) { values, section in
            values[section.title] = section.content
        }
        summary = byTitle["Summary"].map(legacyTrimmed)
        keyTopics = parseTopics(byTitle["Key Topics"] ?? "")
        keyPoints = parseBullets(byTitle["Key Points"] ?? "")
        actionItems = parseBullets(byTitle["Action Items"] ?? "")
        participants = (byTitle["Participants"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        transcript = byTitle["Transcript"].map(legacyTrimmed)
        userNotes = byTitle["User Notes"].map(legacyTrimmed)
    }
}

public struct LegacySummaryFile: Equatable, Sendable {
    public let frontmatter: [String: LegacyFrontmatterValue]
    public let body: LegacySummaryBody
    public let title: String?
    public let date: Date?
    public let transcriptCorrectedAt: Date?
    public let summaryGeneratedAt: Date?
    public let updatedAt: Date?
    public let durationSeconds: Int?
    public let isDiarised: Bool?
    public let processing: Bool?
    public let folders: [String]

    public init(
        frontmatter: [String: LegacyFrontmatterValue],
        body: LegacySummaryBody,
        timestampParser: LegacyTimestampParser
    ) {
        self.frontmatter = frontmatter
        self.body = body
        title = frontmatter["title"]?.stringValue
        date = frontmatter["date"]?.stringValue.flatMap(timestampParser.date(fromISO8601:))
        transcriptCorrectedAt = frontmatter["transcript_corrected_at"]?.stringValue
            .flatMap(timestampParser.date(fromISO8601:))
        summaryGeneratedAt = frontmatter["summary_generated_at"]?.stringValue
            .flatMap(timestampParser.date(fromISO8601:))
        updatedAt = frontmatter["updated_at"]?.stringValue
            .flatMap(timestampParser.date(fromISO8601:))
        durationSeconds = frontmatter["duration_seconds"]?.integerValue
        isDiarised = frontmatter["is_diarised"]?.boolValue
        processing = frontmatter["processing"]?.boolValue
        folders = frontmatter["folders"]?.stringArrayValue ?? []
    }

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = contents.components(separatedBy: "\n")
        guard lines.first == "---",
              let closingOffset = lines.dropFirst().firstIndex(of: "---") else {
            throw LegacyExchangeError.invalidFormat("Missing summary frontmatter")
        }

        var frontmatter: [String: LegacyFrontmatterValue] = [:]
        for line in lines[1..<closingOffset] where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            frontmatter[key] = try parseFrontmatterValue(value)
        }
        let bodyText = lines.dropFirst(closingOffset + 1).joined(separator: "\n")
        return Self(
            frontmatter: frontmatter,
            body: LegacySummaryBody(sections: parseSummarySections(bodyText)),
            timestampParser: timestampParser
        )
    }
}

private extension LegacyFrontmatterValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var stringArrayValue: [String]? {
        guard case let .array(values) = self else { return nil }
        return values.compactMap { value in
            guard case let .string(string) = value else { return nil }
            return string
        }
    }
}

private func parseFrontmatterValue(_ value: String) throws -> LegacyFrontmatterValue {
    if value.count >= 2, value.first == "\"", value.last == "\"" {
        return .string(String(value.dropFirst().dropLast()))
    }
    if value.first == "[" {
        guard let data = value.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw LegacyExchangeError.invalidFormat("Invalid frontmatter JSON array")
        }
        return .array(try array.map(LegacyJSONValue.init(jsonObject:)))
    }
    switch value {
    case "null": return .null
    case "true": return .bool(true)
    case "false": return .bool(false)
    default:
        if value.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil,
           let integer = Int(value) {
            return .integer(integer)
        }
        return .string(value)
    }
}

private func parseSummarySections(_ body: String) -> [LegacySummarySection] {
    var result: [LegacySummarySection] = []
    var title: String?
    var content: [String] = []
    func appendSection() {
        guard let title else { return }
        result.append(LegacySummarySection(
            title: title,
            content: content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }
    for line in body.components(separatedBy: "\n") {
        if line.hasPrefix("## ") {
            appendSection()
            title = String(line.dropFirst(3))
            content = []
        } else if title != nil {
            content.append(line)
        }
    }
    appendSection()
    return result
}

private func parseTopics(_ content: String) -> [LegacySummaryTopic] {
    var result: [LegacySummaryTopic] = []
    var title: String?
    var body: [String] = []
    func appendTopic() {
        guard let title else { return }
        result.append(LegacySummaryTopic(
            title: title,
            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }
    for line in content.components(separatedBy: "\n") {
        if line.hasPrefix("### ") {
            appendTopic()
            title = String(line.dropFirst(4))
            body = []
        } else if title != nil {
            body.append(line)
        }
    }
    appendTopic()
    return result
}

private func parseBullets(_ content: String) -> [String] {
    content.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}
