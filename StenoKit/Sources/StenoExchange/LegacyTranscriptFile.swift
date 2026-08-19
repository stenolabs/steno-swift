import Foundation

public struct LegacyTranscriptHeader: Equatable, Sendable {
    public let sessionName: String
    public let fileName: String
    public let date: Date?
    public let languageSetting: String
    public let detectedLanguage: String
    public let summaryOutputLanguage: String

    public init(
        sessionName: String,
        fileName: String,
        date: Date?,
        languageSetting: String,
        detectedLanguage: String,
        summaryOutputLanguage: String
    ) {
        self.sessionName = sessionName
        self.fileName = fileName
        self.date = date
        self.languageSetting = languageSetting
        self.detectedLanguage = detectedLanguage
        self.summaryOutputLanguage = summaryOutputLanguage
    }
}

public struct LegacyTranscriptTurn: Equatable, Sendable {
    public let start: TimeInterval
    public let speaker: String
    public let text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

public enum LegacyTranscriptBody: Equatable, Sendable {
    case diarized([LegacyTranscriptTurn])
    case plain([String])

    public var diarizedTurns: [LegacyTranscriptTurn]? {
        guard case let .diarized(turns) = self else { return nil }
        return turns
    }

    public var plainParagraphs: [String]? {
        guard case let .plain(paragraphs) = self else { return nil }
        return paragraphs
    }
}

public struct LegacyTranscriptFile: Equatable, Sendable {
    public let header: LegacyTranscriptHeader
    public let body: LegacyTranscriptBody

    public init(header: LegacyTranscriptHeader, body: LegacyTranscriptBody) {
        self.header = header
        self.body = body
    }

    public static func read(
        from url: URL,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) throws -> Self {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = contents.components(separatedBy: "\n")
        guard let separator = lines.firstIndex(where: { line in
            line.count == 60 && line.allSatisfy { $0 == "=" }
        }) else {
            throw LegacyExchangeError.invalidFormat("Missing transcript header separator")
        }

        var fields: [String: String] = [:]
        for line in lines[..<separator] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        let bodyText = lines.dropFirst(separator + 1).joined(separator: "\n")
        let paragraphs = splitLegacyParagraphs(bodyText)
        let parsedTurns = paragraphs.compactMap(parseDiarizedTurn)
        let body: LegacyTranscriptBody = parsedTurns.count == paragraphs.count && !parsedTurns.isEmpty
            ? .diarized(parsedTurns)
            : .plain(paragraphs)

        return Self(
            header: LegacyTranscriptHeader(
                sessionName: fields["Session"] ?? "",
                fileName: fields["File"] ?? "",
                date: fields["Date"].flatMap(timestampParser.date(fromLegacyHeader:)),
                languageSetting: fields["Language setting"] ?? "",
                detectedLanguage: fields["Detected language"] ?? "",
                summaryOutputLanguage: fields["Summary output language"] ?? ""
            ),
            body: body
        )
    }
}

private func splitLegacyParagraphs(_ text: String) -> [String] {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return normalized.components(separatedBy: "\n\n")
        .map(legacyTrimmed)
        .filter { !$0.isEmpty }
}

private func parseDiarizedTurn(_ paragraph: String) -> LegacyTranscriptTurn? {
    guard !paragraph.contains("\n") else { return nil }
    let pattern = #"^\[([0-9]+:[0-9]{2}(?::[0-9]{2})?)\] \[([^\]]+)\] (.*)$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)
    guard let match = expression.firstMatch(in: paragraph, range: range), match.range == range,
          let stampRange = Range(match.range(at: 1), in: paragraph),
          let speakerRange = Range(match.range(at: 2), in: paragraph),
          let textRange = Range(match.range(at: 3), in: paragraph),
          let start = parseRelativeTimestamp(String(paragraph[stampRange])) else {
        return nil
    }
    return LegacyTranscriptTurn(
        start: start,
        speaker: String(paragraph[speakerRange]),
        text: String(paragraph[textRange])
    )
}

private func parseRelativeTimestamp(_ value: String) -> TimeInterval? {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 || parts.count == 3 else { return nil }
    if parts.count == 2 {
        guard parts[1] < 60 else { return nil }
        return TimeInterval(parts[0] * 60 + parts[1])
    }
    guard parts[1] < 60, parts[2] < 60 else { return nil }
    return TimeInterval(parts[0] * 3_600 + parts[1] * 60 + parts[2])
}
