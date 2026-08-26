import Foundation
import Testing
@testable import StenoIntelligence

/// Tool-surface behavior: schemas, argument bounds, facade error mapping,
/// and the cross-note chat timeout that kills the running ask task.
@Suite("MCP tools")
struct MCPToolsTests {
    // MARK: Stubs

    /// Facade stub that records calls and can be programmed to fail, hang,
    /// or observe cancellation.
    private final class StubFacade: MCPMeetingFacade, @unchecked Sendable {
        let lock = NSLock()
        var meetings: [MCPMeetingSummary] = []
        var folders: [MCPFolderInfo] = []
        var searchHits: [MCPSearchHit] = []
        var detailByID: [String: MCPMeetingDetail] = [:]
        var transcriptByID: [String: (title: String, text: String)] = [:]
        var askError: Error?
        /// When set, ask sleeps this long and honours cancellation.
        var askDelaySeconds: TimeInterval?
        /// Set when a hanging ask observes cooperative cancellation.
        var observedCancellation = false

        func listMeetings(limit: Int) async throws -> [MCPMeetingSummary] {
            Array(meetings.prefix(limit))
        }

        func getMeeting(meetingID: String) async throws -> MCPMeetingDetail {
            guard let detail = detailByID[meetingID] else {
                throw MCPFacadeError.invalidID(meetingID)
            }
            return detail
        }

        func getTranscript(meetingID: String) async throws -> (title: String, text: String) {
            guard let transcript = transcriptByID[meetingID] else {
                throw MCPFacadeError.invalidID(meetingID)
            }
            return transcript
        }

        func search(query _: String, limit: Int) async throws -> [MCPSearchHit] {
            Array(searchHits.prefix(limit))
        }

        func folders() async throws -> [MCPFolderInfo] {
            folders
        }

        func ask(question _: String, meetingIDs _: [String]?, folderID _: String?) async throws -> String {
            if let askError {
                throw askError
            }
            guard let askDelaySeconds else { return "answer" }
            do {
                try await Task.sleep(for: .seconds(askDelaySeconds))
            } catch {
                markCancelled()
                throw CancellationError()
            }
            return "slow answer"
        }

        private func markCancelled() {
            lock.lock()
            observedCancellation = true
            lock.unlock()
        }
        func wasCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return observedCancellation
        }
    }

    private func summary(
        id: String = "m1",
        title: String = "Weekly Sync",
        date: String = "2026-08-01T10:00:00Z"
    ) -> MCPMeetingSummary {
        MCPMeetingSummary(
            id: id,
            title: title,
            date: date,
            durationSeconds: 3_600,
            folders: ["Work"],
            attendees: ["Ada", "Grace"]
        )
    }

    // MARK: Schemas

    @Test("exactly six tools, every schema closed with additionalProperties false")
    func toolDefinitionsShape() {
        let toolkit = MCPToolkit(facade: StubFacade())
        #expect(toolkit.definitions.count == 6)

        for definition in toolkit.definitions {
            #expect(definition.inputSchema["additionalProperties"]?.boolValue == false)
            #expect(definition.inputSchema["type"]?.stringValue == "object")
            #expect(definition.inputSchema["properties"] != nil)
        }

        let requiredByTool = Dictionary(uniqueKeysWithValues: toolkit.definitions.map {
            ($0.name, $0.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        })
        #expect(requiredByTool["get_meeting"] == ["meeting_id"])
        #expect(requiredByTool["get_meeting_transcript"] == ["meeting_id"])
        #expect(requiredByTool["search_meetings"] == ["query"])
        #expect(requiredByTool["ask_meetings"] == ["question"])
        #expect(requiredByTool["list_meetings"]?.isEmpty == true)
        #expect(requiredByTool["list_folders"]?.isEmpty == true)
    }

    // MARK: limit bounds

    @Test("limit clamps into 1...200 with default 20")
    func limitClamping() {
        #expect(MCPToolkit.clampLimit([:]) == 20)
        #expect(MCPToolkit.clampLimit(["limit": .number(0)]) == 1)
        #expect(MCPToolkit.clampLimit(["limit": .number(-5)]) == 1)
        #expect(MCPToolkit.clampLimit(["limit": .number(201)]) == 200)
        #expect(MCPToolkit.clampLimit(["limit": .number(50)]) == 50)
        #expect(MCPToolkit.clampLimit(["limit": .string("30")]) == 20)
        // Fractional limits floor.
        #expect(MCPToolkit.clampLimit(["limit": .number(2.9)]) == 2)
    }

    // MARK: list / get / transcript / search / folders

    @Test("list_meetings maps facade data into text plus structuredContent")
    func listMeetingsHappyPath() async {
        let facade = StubFacade()
        facade.meetings = [summary(), summary(id: "m2", title: "Retro")]
        let output = await MCPToolkit(facade: facade).call(
            name: "list_meetings",
            arguments: .object([:])
        )

        #expect(!output.isError)
        #expect(output.text.contains("Found 2 meeting(s)"))
        #expect(output.text.contains("**Weekly Sync**"))
        let meetings = output.structuredContent["meetings"]?.arrayValue ?? []
        #expect(meetings.count == 2)
        #expect(meetings.first?["duration_seconds"]?.intValue == 3_600)
        #expect(meetings.first?["attendees"]?.arrayValue?.first?.stringValue == "Ada")
    }

    @Test("get_meeting without transcript and invalid-ID mapping")
    func getMeetingBehavior() async {
        let facade = StubFacade()
        facade.detailByID["m1"] = MCPMeetingDetail(
            summary: summary(),
            reportMarkdown: "## Summary\nDecided.",
            keyPoints: ["One"],
            actionItems: [],
            userNotes: "my note"
        )
        let toolkit = MCPToolkit(facade: facade)

        let ok = await toolkit.call(name: "get_meeting", arguments: .object(["meeting_id": "m1"]))
        #expect(!ok.isError)
        #expect(ok.text.contains("# Weekly Sync"))
        #expect(ok.text.contains("Duration: 60 min (3600s)"))
        // Detail must not carry transcript content anywhere.
        #expect(ok.structuredContent["transcript"] == nil)

        let missing = await toolkit.call(
            name: "get_meeting",
            arguments: .object(["meeting_id": "ghost"])
        )
        #expect(missing.isError)
        #expect(missing.text == "Invalid meeting_id: validation failed")

        let emptyArg = await toolkit.call(name: "get_meeting", arguments: .object([:]))
        #expect(emptyArg.isError)
        #expect(emptyArg.text == "Invalid meeting_id: argument is required")
    }

    @Test("empty transcript renders the fixed fallback sentence")
    func transcriptFallback() async {
        let facade = StubFacade()
        facade.transcriptByID["m1"] = ("Weekly Sync", "")
        facade.transcriptByID["m2"] = ("Retro", "spoken words")

        let toolkit = MCPToolkit(facade: facade)
        let empty = await toolkit.call(
            name: "get_meeting_transcript",
            arguments: .object(["meeting_id": "m1"])
        )
        #expect(!empty.isError)
        #expect(empty.text == "(No transcript available for this meeting)")
        // Raw structured value stays honest about absence.
        #expect(empty.structuredContent["transcript"]?.stringValue == "")

        let present = await toolkit.call(
            name: "get_meeting_transcript",
            arguments: .object(["meeting_id": "m2"])
        )
        #expect(present.text == "spoken words")
    }

    @Test("search validates query length and forwards matched fields")
    func searchBehavior() async {
        let facade = StubFacade()
        facade.searchHits = [
            MCPSearchHit(meeting: summary(), matchedFields: ["title", "user_notes"]),
        ]
        let toolkit = MCPToolkit(facade: facade)

        let tooLong = await toolkit.call(
            name: "search_meetings",
            arguments: .object(["query": .string(String(repeating: "a", count: 501))])
        )
        #expect(tooLong.isError)
        #expect(tooLong.text.contains("exceeds maximum length of 500 characters"))

        let blank = await toolkit.call(
            name: "search_meetings",
            arguments: .object(["query": "   "])
        )
        #expect(blank.text == "Invalid query: search query must be a non-empty string")

        let ok = await toolkit.call(
            name: "search_meetings",
            arguments: .object(["query": "sync", "limit": 5])
        )
        #expect(!ok.isError)
        let results = ok.structuredContent["results"]?.arrayValue ?? []
        let fields = results.first?["matched_fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(fields == ["title", "user_notes"])
        #expect(ok.text.contains("(matched in: title, user_notes)"))
    }

    @Test("list_folders maps facade folders; backend failures become isError")
    func foldersAndBackendFailures() async {
        let facade = StubFacade()
        facade.folders = [MCPFolderInfo(id: "f1", name: "Work")]
        let toolkit = MCPToolkit(facade: facade)

        let ok = await toolkit.call(name: "list_folders", arguments: .object([:]))
        #expect(!ok.isError)
        #expect(ok.text.contains("**Work**"))

        facade.askError = MCPFacadeError.backendFailure
        facade.folders = []
        // Force a backend failure through a throwing facade call.
        let failing = FailingFoldersFacade()
        let failed = await MCPToolkit(facade: failing).call(
            name: "list_folders",
            arguments: .object([:])
        )
        _ = facade
        #expect(failed.isError)
        #expect(failed.text == "Failed to list folders from backend")
    }

    private struct FailingFoldersFacade: MCPMeetingFacade {
        func listMeetings(limit _: Int) async throws -> [MCPMeetingSummary] { [] }
        func getMeeting(meetingID _: String) async throws -> MCPMeetingDetail {
            throw MCPFacadeError.backendFailure
        }
        func getTranscript(meetingID _: String) async throws -> (title: String, text: String) {
            throw MCPFacadeError.backendFailure
        }
        func search(query _: String, limit _: Int) async throws -> [MCPSearchHit] {
            throw MCPFacadeError.backendFailure
        }
        func folders() async throws -> [MCPFolderInfo] {
            throw MCPFacadeError.backendFailure
        }
        func ask(question _: String, meetingIDs _: [String]?, folderID _: String?) async throws -> String {
            throw MCPFacadeError.backendFailure
        }
    }

    // MARK: ask_meetings validation

    @Test("ask_meetings argument bounds and scope normalization")
    func askValidation() async {
        let facade = StubFacade()
        let toolkit = MCPToolkit(facade: facade)

        func ask(_ arguments: [String: MCPJSON]) async -> MCPToolOutput {
            await toolkit.call(name: "ask_meetings", arguments: .object(arguments))
        }

        let emptyQuestion = await ask(["question": "  "])
        #expect(emptyQuestion.text == "Invalid question: question must be a non-empty string")

        let longQuestion = await ask(["question": .string(String(repeating: "q", count: 4_001))])
        #expect(longQuestion.text.contains("exceeds maximum length of 4000 characters"))

        let idsNotArray = await ask([
            "question": "hi",
            "meeting_ids": "not-an-array",
        ])
        #expect(idsNotArray.text == "Invalid meeting_ids: must be an array of string IDs")

        let tooManyIDs = await ask([
            "question": "hi",
            "meeting_ids": .array((0...50).map { .string("\($0)") }),
        ])
        #expect(tooManyIDs.text.contains("exceeds maximum count of 50 IDs"))

        let folderTooLong = await ask([
            "question": "hi",
            "folder_id": .string(String(repeating: "f", count: 101)),
        ])
        #expect(folderTooLong.text.contains("exceeds maximum length of 100 characters"))

        let happy = await ask(["question": "What did we decide?"])
        #expect(happy.text == "answer")
        #expect(happy.structuredContent["question"]?.stringValue == "What did we decide?")
        #expect(happy.structuredContent["answer"]?.stringValue == "answer")

        // An empty meeting_ids array means "unset": the stub answers.
        let emptyScope = await ask(["question": "hi", "meeting_ids": .array([])])
        #expect(emptyScope.text == "answer")
    }

    // MARK: Timeout kill

    @Test("timed-out ask is killed cooperatively and reported as isError")
    func askTimeoutKillsTask() async {
        let facade = StubFacade()
        facade.askDelaySeconds = 10
        let toolkit = MCPToolkit(facade: facade, askTimeoutSeconds: 0.2)

        let start = Date()
        let output = await toolkit.call(
            name: "ask_meetings",
            arguments: .object(["question": "long running?"])
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(output.isError)
        #expect(output.text == "Cross-note chat timed out")
        // The race must resolve near the timeout, never after the facade's
        // ten-second delay.
        #expect(elapsed < 5)
        // The losing child task observed cooperative cancellation.
        #expect(facade.wasCancelled())
    }

    @Test("unknown tools answer isError at the tool level")
    func unknownTool() async {
        let output = await MCPToolkit(facade: StubFacade()).call(
            name: "no_such_tool",
            arguments: .object([:])
        )
        #expect(output.isError)
        #expect(output.text == "Unknown tool")
    }

    @Test("facade errors degrade to isError, never thrown transport errors")
    func askFacadeErrors() async {
        let invalidIDFacade = StubFacade()
        invalidIDFacade.askError = MCPFacadeError.invalidID("ghost")
        let invalid = await MCPToolkit(facade: invalidIDFacade).call(
            name: "ask_meetings",
            arguments: .object(["question": "hi", "meeting_ids": ["ghost"]])
        )
        #expect(invalid.isError)
        #expect(invalid.text == "Invalid meeting_ids: validation failed")

        let backendFacade = StubFacade()
        backendFacade.askError = MCPFacadeError.backendFailure
        let backend = await MCPToolkit(facade: backendFacade).call(
            name: "ask_meetings",
            arguments: .object(["question": "hi"])
        )
        #expect(backend.isError)
        #expect(backend.text == "Cross-note chat failed")
    }

    // MARK: Text rendering parity

    @Test("text renderers keep legacy formatting details")
    func textRendering() {
        let toolkit = MCPToolkit(facade: StubFacade())
        #expect(toolkit.formatMeetingListText([]) == "No meetings found.")
        #expect(toolkit.formatFolderListText([]) == "No folders found.")
        #expect(toolkit.formatSearchResultsText("q", []) == "No meetings found matching \"q\".")

        let listing = toolkit.formatMeetingListText([summary()])
        #expect(listing.contains("- **Weekly Sync** (60 min) - 2026-08-01T10:00:00Z [Attendees: Ada, Grace]"))
        #expect(listing.contains("  ID: `m1`"))
    }
}
