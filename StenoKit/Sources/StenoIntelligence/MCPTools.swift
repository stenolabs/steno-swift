import Foundation

// MARK: - Bounds (ported verbatim from the legacy surface)

/// Default meetings per page.
public let MCPLimitDefault = 20
/// Minimum meetings per page.
public let MCPLimitMin = 1
/// Maximum meetings per page.
public let MCPLimitMax = 200
/// Maximum `ask_meetings` question length in characters.
public let MCPQuestionMaxLength = 4_000
/// Maximum `search_meetings` query length in characters.
public let MCPSearchQueryMaxLength = 500
/// Maximum number of meeting IDs accepted by `ask_meetings`.
public let MCPMeetingIDsMaxCount = 50
/// Maximum `folder_id` length in characters.
public let MCPFolderIDMaxLength = 100
/// Hard timeout for one cross-note chat run; the running chat task is killed
/// when it elapses.
public let MCPAskTimeoutSeconds: TimeInterval = 60

// MARK: - Facade data types

/// One meeting in a list/search result: metadata only, never content.
public struct MCPMeetingSummary: Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    /// ISO 8601 timestamp string as presented to external clients.
    public var date: String
    public var durationSeconds: Int?
    public var folders: [String]
    public var attendees: [String]

    public init(
        id: String,
        title: String,
        date: String,
        durationSeconds: Int?,
        folders: [String],
        attendees: [String]
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.folders = folders
        self.attendees = attendees
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case durationSeconds = "duration_seconds"
        case folders
        case attendees
    }
}

/// Full meeting detail WITHOUT transcript text.
public struct MCPMeetingDetail: Equatable, Sendable {
    public var summary: MCPMeetingSummary
    /// Latest report markdown; empty when the meeting has no report yet.
    public var reportMarkdown: String
    public var keyPoints: [String]
    public var actionItems: [String]
    public var userNotes: String?

    public init(
        summary: MCPMeetingSummary,
        reportMarkdown: String,
        keyPoints: [String],
        actionItems: [String],
        userNotes: String?
    ) {
        self.summary = summary
        self.reportMarkdown = reportMarkdown
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.userNotes = userNotes
    }
}

/// One search hit with the fields that matched the query.
public struct MCPSearchHit: Equatable, Sendable {
    public var meeting: MCPMeetingSummary
    public var matchedFields: [String]

    public init(meeting: MCPMeetingSummary, matchedFields: [String]) {
        self.meeting = meeting
        self.matchedFields = matchedFields
    }
}

/// One folder entry.
public struct MCPFolderInfo: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Failure contract between facade and toolkit. Every case degrades to a
/// tool-level error result - backend problems must never become transport
/// errors.
public enum MCPFacadeError: Error, Equatable, Sendable {
    /// A referenced identifier is missing, malformed, or unknown.
    case invalidID(String)
    /// Reading or asking failed on the backing store or model.
    case backendFailure
}

// MARK: - Facade protocol

/// Backing-data seam for the MCP tool surface. Unit tests stub this; the
/// app-side controller maps it onto the Library and the library chat
/// pipeline.
public protocol MCPMeetingFacade: Sendable {
    /// Up to `limit` meetings, newest first.
    func listMeetings(limit: Int) async throws -> [MCPMeetingSummary]

    /// Full detail for one meeting, without transcript text. Throws
    /// `.invalidID` for an unknown identifier.
    func getMeeting(meetingID: String) async throws -> MCPMeetingDetail

    /// Full transcript text for one meeting; an empty string means no
    /// transcript exists. Throws `.invalidID` for an unknown identifier.
    func getTranscript(meetingID: String) async throws -> (title: String, text: String)

    /// Case-insensitive substring search across titles, summaries, notes,
    /// attendees, and folders, returning matched field names per hit.
    func search(query: String, limit: Int) async throws -> [MCPSearchHit]

    /// All folders.
    func folders() async throws -> [MCPFolderInfo]

    /// Runs one cross-note chat answer over the given scope. When both
    /// scopes are nil the whole library answers. The implementation must
    /// honour cooperative cancellation so the timeout can kill it.
    func ask(
        question: String,
        meetingIDs: [String]?,
        folderID: String?
    ) async throws -> String
}

// MARK: - Tool definitions

/// One advertised tool: name plus JSON Schema.
public struct MCPToolDefinition: Equatable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: MCPJSON

    public init(name: String, title: String, description: String, inputSchema: MCPJSON) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }
}

extension MCPToolOutput {
    /// Result-envelope members (`content`, optional `structuredContent`,
    /// optional `isError`). The dispatcher stamps `resultType` itself.
    func payloadDictionary() -> [String: MCPJSON] {
        var payload: [String: MCPJSON] = [
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "structuredContent": structuredContent,
        ]
        if isError {
            payload["isError"] = true
        }
        return payload
    }
}

/// Outcome of one tool execution, already normalized into result envelope
/// members (`content`, optional `structuredContent`, optional `isError`).
public struct MCPToolOutput: Equatable, Sendable {
    public let text: String
    public let structuredContent: MCPJSON
    public let isError: Bool

    public init(text: String, structuredContent: MCPJSON, isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }


    static let unknownTool = MCPToolOutput(
        text: "Unknown tool",
        structuredContent: .object(["error": "Unknown tool"]),
        isError: true
    )

    static let executionFailed = MCPToolOutput(
        text: "Tool execution failed",
        structuredContent: .object(["error": "Tool execution failed"]),
        isError: true
    )

    static func failure(_ message: String) -> MCPToolOutput {
        MCPToolOutput(
            text: message,
            structuredContent: .object(["error": .string(message)]),
            isError: true
        )
    }
}

// MARK: - Toolkit

/// The six tools over any `MCPMeetingFacade`, including argument validation,
/// human-readable text rendering, and the cross-note chat timeout that kills
/// a hung ask run.
public struct MCPToolkit: Sendable {
    public let facade: any MCPMeetingFacade
    public let askTimeoutSeconds: TimeInterval

    public init(facade: any MCPMeetingFacade, askTimeoutSeconds: TimeInterval = MCPAskTimeoutSeconds) {
        self.facade = facade
        self.askTimeoutSeconds = askTimeoutSeconds
    }

    // MARK: Definitions

    /// The exactly-six advertised tool definitions. Schemas reject unknown
    /// properties outright (`additionalProperties: false`).
    public var definitions: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_meetings",
                title: "List Meetings",
                description:
                "List recorded and processed meetings sorted newest-first. Returns metadata "
                    + "including note ID, title, date, duration, folders, and attendees. Does not "
                    + "return meeting summaries or transcripts.",
                inputSchema: schema(properties: [
                    "limit": .object([
                        "type": "integer",
                        "description": "Maximum number of meetings to return (default 20, max 200)",
                        "default": 20,
                        "minimum": 1,
                        "maximum": 200,
                    ]),
                ])
            ),
            MCPToolDefinition(
                name: "get_meeting",
                title: "Get Meeting Details",
                description:
                "Retrieve details and summary of a specific meeting by its meeting ID. Returns "
                    + "title, date, duration, folders, attendees, summary, key points, action items, "
                    + "and user notes. Does not return the full transcript (use "
                    + "get_meeting_transcript for transcript text).",
                inputSchema: schema(
                    properties: [
                        "meeting_id": .object([
                            "type": "string",
                            "description": "The meeting identifier",
                        ]),
                    ],
                    required: ["meeting_id"]
                )
            ),
            MCPToolDefinition(
                name: "get_meeting_transcript",
                title: "Get Meeting Transcript",
                description:
                "Retrieve the full transcript text for a specific meeting by its meeting ID.",
                inputSchema: schema(
                    properties: [
                        "meeting_id": .object([
                            "type": "string",
                            "description": "The meeting identifier",
                        ]),
                    ],
                    required: ["meeting_id"]
                )
            ),
            MCPToolDefinition(
                name: "search_meetings",
                title: "Search Meetings",
                description:
                "Search meetings by substring query across title, summary, key points, action "
                    + "items, user notes, and attendees.",
                inputSchema: schema(
                    properties: [
                        "query": .object([
                            "type": "string",
                            "description": .string(
                                "Search keyword or phrase to match against meeting metadata "
                                    + "and summary content"
                            ),
                        ]),
                        "limit": .object([
                            "type": "integer",
                            "description": .string(
                                "Maximum number of matching meetings to return "
                                    + "(default 20, max 200)"
                            ),
                            "default": 20,
                            "minimum": 1,
                            "maximum": 200,
                        ]),
                    ],
                    required: ["query"]
                )
            ),
            MCPToolDefinition(
                name: "list_folders",
                title: "List Folders",
                description:
                "List all meeting folders and their metadata including folder IDs and names.",
                inputSchema: schema(properties: [:])
            ),
            MCPToolDefinition(
                name: "ask_meetings",
                title: "Ask Across Meetings",
                description:
                "Ask a question across meeting notes using cross-note AI synthesis. Can be "
                    + "scoped to specific meeting IDs or a folder ID. Note: this tool executes an "
                    + "LLM model call.",
                inputSchema: schema(
                    properties: [
                        "question": .object([
                            "type": "string",
                            "description": "Question to ask across the meeting notes",
                        ]),
                        "meeting_ids": .object([
                            "type": "array",
                            "items": .object(["type": "string"]),
                            "description":
                            "Optional list of meeting IDs to restrict the answer corpus to",
                        ]),
                        "folder_id": .object([
                            "type": "string",
                            "description": .string(
                                "Optional folder ID to restrict the answer corpus to "
                                    + "(ignored if meeting_ids is provided)"
                            ),
                        ]),
                    ],
                    required: ["question"]
                )
            ),
        ]
    }

    private func schema(properties: [String: MCPJSON], required: [String]? = nil) -> MCPJSON {
        var object: [String: MCPJSON] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if let required {
            object["required"] = .array(required.map(MCPJSON.string))
        }
        return .object(object)
    }

    // MARK: Dispatch

    /// Executes one named tool call. Never throws: every failure mode -
    /// invalid arguments, facade errors, timeouts - becomes an `isError`
    /// output so transports keep answering HTTP 200 for tool calls.
    public func call(name: String, arguments: MCPJSON) async -> MCPToolOutput {
        let arguments = arguments.objectValue ?? [:]
        switch name {
        case "list_meetings":
            return await listMeetings(arguments)
        case "get_meeting":
            return await getMeeting(arguments)
        case "get_meeting_transcript":
            return await getMeetingTranscript(arguments)
        case "search_meetings":
            return await searchMeetings(arguments)
        case "list_folders":
            return await listFolders()
        case "ask_meetings":
            return await askMeetings(arguments)
        default:
            return .unknownTool
        }
    }

    // MARK: Argument helpers

    /// Clamps the `limit` argument into 1...200; absent or non-numeric values
    /// fall back to the default of 20. Fractional values floor.
    static func clampLimit(_ arguments: [String: MCPJSON]) -> Int {
        guard case .number(let raw)? = arguments["limit"] else {
            return MCPLimitDefault
        }
        let floored = Int(raw.rounded(.down))
        return min(max(floored, MCPLimitMin), MCPLimitMax)
    }

    private func requiredString(_ arguments: [String: MCPJSON], _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Tools

    private func listMeetings(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
        let limit = Self.clampLimit(arguments)
        do {
            let meetings = try await facade.listMeetings(limit: limit)
            let payload = meetings.map { meeting -> MCPJSON in
                encodeSummary(meeting)
            }
            return MCPToolOutput(
                text: formatMeetingListText(meetings),
                structuredContent: .object(["meetings": .array(payload)])
            )
        } catch {
            return .failure("Failed to list meetings from backend")
        }
    }

    private func getMeeting(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
        guard let meetingID = requiredString(arguments, "meeting_id") else {
            return .failure("Invalid meeting_id: argument is required")
        }
        do {
            let detail = try await facade.getMeeting(meetingID: meetingID)
            var structured: [String: MCPJSON] = encodeSummaryDictionary(detail.summary)
            structured["summary"] = .string(detail.reportMarkdown)
            structured["key_points"] = .array(detail.keyPoints.map(MCPJSON.string))
            structured["action_items"] = .array(detail.actionItems.map(MCPJSON.string))
            structured["user_notes"] = detail.userNotes.map(MCPJSON.string) ?? .null
            return MCPToolOutput(
                text: formatMeetingDetailText(detail),
                structuredContent: .object(structured)
            )
        } catch MCPFacadeError.invalidID {
            return .failure("Invalid meeting_id: validation failed")
        } catch {
            return .failure("Failed to read meeting file")
        }
    }

    private func getMeetingTranscript(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
        guard let meetingID = requiredString(arguments, "meeting_id") else {
            return .failure("Invalid meeting_id: argument is required")
        }
        do {
            let (title, text) = try await facade.getTranscript(meetingID: meetingID)
            let output = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "(No transcript available for this meeting)"
                : text
            return MCPToolOutput(
                text: output,
                structuredContent: .object([
                    "id": .string(meetingID),
                    "title": .string(title),
                    "transcript": .string(text),
                ])
            )
        } catch MCPFacadeError.invalidID {
            return .failure("Invalid meeting_id: validation failed")
        } catch {
            return .failure("Failed to read meeting file")
        }
    }

    private func searchMeetings(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
        guard let query = requiredString(arguments, "query") else {
            return .failure("Invalid query: search query must be a non-empty string")
        }
        guard query.count <= MCPSearchQueryMaxLength else {
            return .failure(
                "Invalid query: exceeds maximum length of \(MCPSearchQueryMaxLength) characters"
            )
        }
        let limit = Self.clampLimit(arguments)
        do {
            let hits = try await facade.search(query: query, limit: limit)
            let payload = hits.map { hit -> MCPJSON in
                var dictionary = encodeSummaryDictionary(hit.meeting)
                dictionary["matched_fields"] = .array(hit.matchedFields.map(MCPJSON.string))
                return .object(dictionary)
            }
            return MCPToolOutput(
                text: formatSearchResultsText(query, hits),
                structuredContent: .object([
                    "query": .string(query),
                    "results": .array(payload),
                ])
            )
        } catch {
            return .failure("Failed to search meetings from backend")
        }
    }

    private func listFolders() async -> MCPToolOutput {
        do {
            let folders = try await facade.folders()
            return MCPToolOutput(
                text: formatFolderListText(folders),
                structuredContent: .object([
                    "folders": .array(folders.map { folder in
                        .object([
                            "id": .string(folder.id),
                            "name": .string(folder.name),
                        ])
                    })
                ])
            )
        } catch {
            return .failure("Failed to list folders from backend")
        }
    }

    private func askMeetings(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
        guard let question = requiredString(arguments, "question") else {
            return .failure("Invalid question: question must be a non-empty string")
        }
        guard question.count <= MCPQuestionMaxLength else {
            return .failure(
                "Invalid question: exceeds maximum length of \(MCPQuestionMaxLength) characters"
            )
        }

        var meetingIDs: [String]?
        if let rawIDs = arguments["meeting_ids"] {
            guard let array = rawIDs.arrayValue else {
                return .failure("Invalid meeting_ids: must be an array of string IDs")
            }
            guard array.count <= MCPMeetingIDsMaxCount else {
                return .failure("Invalid meeting_ids: exceeds maximum count of \(MCPMeetingIDsMaxCount) IDs")
            }
            let identifiers = array.compactMap(\.stringValue)
            guard identifiers.count == array.count else {
                return .failure("Invalid meeting_ids: must be an array of string IDs")
            }
            // An empty array means "unset", same as omitting the argument.
            meetingIDs = identifiers.isEmpty ? nil : identifiers
        }

        var folderID: String?
        if let rawFolder = arguments["folder_id"], !(rawFolder == .null) {
            guard let trimmed = rawFolder.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .failure("Invalid folder_id: must be a string")
            }
            guard trimmed.count <= MCPFolderIDMaxLength else {
                return .failure("Invalid folder_id: exceeds maximum length of \(MCPFolderIDMaxLength) characters")
            }
            // 'all' and empty mean unset; explicit IDs win over a folder.
            if !trimmed.isEmpty, trimmed != "all" {
                folderID = trimmed
            }
        }
        if meetingIDs != nil {
            folderID = nil
        }

        // Rebound to immutable locals so the child tasks capture fixed
        // values under strict concurrency.
        let scopedMeetingIDs = meetingIDs
        let scopedFolderID = folderID
        let outcome = await withTaskGroup(of: AskOutcome.self) { group -> AskOutcome in
            group.addTask {
                do {
                    let answer = try await self.facade.ask(
                        question: question,
                        meetingIDs: scopedMeetingIDs,
                        folderID: scopedFolderID
                    )
                    return .answered(answer)
                } catch is CancellationError {
                    return .failed("Cross-note chat failed")
                } catch let error as MCPFacadeError {
                    switch error {
                    case .invalidID:
                        return .failed("Invalid meeting_ids: validation failed")
                    case .backendFailure:
                        return .failed("Cross-note chat failed")
                    }
                } catch {
                    return .failed("Cross-note chat failed")
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(self.askTimeoutSeconds))
                } catch {}
                return .timedOut
            }
            guard let first = await group.next() else { return .failed("Cross-note chat failed") }
            // Cancelling the group kills the losing child - a timed-out ask
            // takes the running chat task down with it.
            group.cancelAll()
            return first
        }

        switch outcome {
        case .answered(let answer):
            return MCPToolOutput(
                text: answer.isEmpty ? "(No response generated)" : answer,
                structuredContent: .object([
                    "question": .string(question),
                    "answer": .string(answer),
                ])
            )
        case .timedOut:
            return .failure("Cross-note chat timed out")
        case .failed(let message):
            return .failure(message)
        }
    }

    private enum AskOutcome {
        case answered(String)
        case failed(String)
        case timedOut
    }


    // MARK: Encoding helpers

    private func encodeSummary(_ summary: MCPMeetingSummary) -> MCPJSON {
        .object(encodeSummaryDictionary(summary))
    }

    private func encodeSummaryDictionary(_ summary: MCPMeetingSummary) -> [String: MCPJSON] {
        [
            "id": .string(summary.id),
            "title": .string(summary.title),
            "date": .string(summary.date),
            "duration_seconds": summary.durationSeconds.map { .number(Double($0)) } ?? .null,
            "folders": .array(summary.folders.map(MCPJSON.string)),
            "attendees": .array(summary.attendees.map(MCPJSON.string)),
        ]
    }

    // MARK: Text rendering (ported from the legacy surface)

    func formatMeetingListText(_ meetings: [MCPMeetingSummary]) -> String {
        guard !meetings.isEmpty else { return "No meetings found." }
        var lines = ["Found \(meetings.count) meeting(s):", ""]
        for meeting in meetings {
            let duration = meeting.durationSeconds.map { " (\($0 / 60) min)" } ?? ""
            let date = meeting.date.isEmpty ? "" : " - \(meeting.date)"
            let attendees = meeting.attendees.isEmpty
                ? ""
                : " [Attendees: \(meeting.attendees.joined(separator: ", "))]"
            lines.append("- **\(meeting.title)**\(duration)\(date)\(attendees)")
            lines.append("  ID: `\(meeting.id)`")
        }
        return lines.joined(separator: "\n")
    }

    func formatMeetingDetailText(_ detail: MCPMeetingDetail) -> String {
        var parts: [String] = []
        parts.append("# \(detail.summary.title)")
        parts.append("ID: `\(detail.summary.id)`")
        if !detail.summary.date.isEmpty {
            parts.append("Date: \(detail.summary.date)")
        }
        if let seconds = detail.summary.durationSeconds {
            parts.append("Duration: \(seconds / 60) min (\(seconds)s)")
        }
        if !detail.summary.attendees.isEmpty {
            parts.append("Attendees: \(detail.summary.attendees.joined(separator: ", "))")
        }
        if !detail.summary.folders.isEmpty {
            parts.append("Folders: \(detail.summary.folders.joined(separator: ", "))")
        }
        if !detail.reportMarkdown.isEmpty {
            parts.append("\n## Summary\n\(detail.reportMarkdown)")
        }
        if !detail.keyPoints.isEmpty {
            parts.append("\n## Key Points\n" + detail.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !detail.actionItems.isEmpty {
            parts.append("\n## Action Items\n" + detail.actionItems.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let userNotes = detail.userNotes, !userNotes.isEmpty {
            parts.append("\n## User Notes\n\(userNotes)")
        }
        return parts.joined(separator: "\n")
    }

    func formatSearchResultsText(_ query: String, _ results: [MCPSearchHit]) -> String {
        guard !results.isEmpty else {
            return "No meetings found matching \"\(query)\"."
        }
        var lines = ["Found \(results.count) meeting(s) matching \"\(query)\":", ""]
        for result in results {
            let meeting = result.meeting
            let duration = meeting.durationSeconds.map { " (\($0 / 60) min)" } ?? ""
            let date = meeting.date.isEmpty ? "" : " - \(meeting.date)"
            let fields = result.matchedFields.isEmpty
                ? ""
                : " (matched in: \(result.matchedFields.joined(separator: ", ")))"
            lines.append("- **\(meeting.title)**\(duration)\(date)\(fields)")
            lines.append("  ID: `\(meeting.id)`")
        }
        return lines.joined(separator: "\n")
    }

    func formatFolderListText(_ folders: [MCPFolderInfo]) -> String {
        guard !folders.isEmpty else { return "No folders found." }
        var lines = ["Found \(folders.count) folder(s):", ""]
        for folder in folders {
            lines.append("- **\(folder.name)** (ID: `\(folder.id)`)")
        }
        return lines.joined(separator: "\n")
    }
}
