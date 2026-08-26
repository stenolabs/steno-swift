import Foundation
import Testing
@testable import StenoIntelligence

/// JSON-RPC dispatch matrix for the MCP surface: protocol version handling,
/// header/body agreement, method routing, and notification semantics.
@Suite("MCP protocol dispatch")
struct MCPProtocolTests {
    private let tools = MCPToolkit(facade: StubFacade()).definitions

    /// Standard modern-era headers for one call.
    private func modernHeaders(method: String, name: String? = nil) -> [String: String] {
        var headers = [
            "mcp-protocol-version": "2026-07-28",
            "mcp-method": method,
        ]
        if let name {
            headers["mcp-name"] = name
        }
        return headers
    }

    private func body(
        method: String,
        id: MCPJSON? = 1,
        params: MCPJSON = .object([:])
    ) -> MCPJSON {
        var object: [String: MCPJSON] = [
            "jsonrpc": "2.0",
            "method": .string(method),
            "params": params,
        ]
        if let id {
            object["id"] = id
        }
        return .object(object)
    }

    /// Sendable recorder box: the dispatcher's callTool closure runs
    /// concurrently, so an inout array cannot be captured.
    private final class ToolRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var items: [(String, MCPJSON)] = []

        var calls: [(String, MCPJSON)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }

        func record(_ name: String, _ arguments: MCPJSON) {
            lock.lock()
            items.append((name, arguments))
            lock.unlock()
        }
    }

    private func call(
        headers: [String: String],
        body: MCPJSON,
        output: MCPToolOutput = MCPToolOutput(text: "ok", structuredContent: .object([:])),
        toolRecorder: ToolRecorder? = nil
    ) async -> MCPHTTPResponse {
        await mcpHandleRPC(
            headers: headers,
            body: body,
            tools: tools,
            callTool: { name, arguments in
                toolRecorder?.record(name, arguments)
                return output
            },
            serverInfo: ["name": "steno"]
        )
    }

    // MARK: Protocol versions

    @Test("every supported version passes the version gate")
    func allSupportedVersionsAccepted() async {
        for version in MCPSupportedProtocolVersions {
            let response = await mcpHandleRPC(
                headers: [
                    "mcp-protocol-version": version,
                    "mcp-method": "ping",
                ],
                body: body(method: "ping"),
                tools: [],
                callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
                serverInfo: [:]
            )
            #expect(response.status == 200)
        }
    }

    @Test("unsupported version yields -32022 with supported list and truncated echo")
    func unsupportedVersionRejected() async {
        let long = String(repeating: "x", count: 300)
        let response = await mcpHandleRPC(
            headers: [
                "mcp-protocol-version": long,
                "mcp-method": "ping",
            ],
            body: body(method: "ping"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(response.status == 400)
        #expect(response.body?["error"]?["code"]?.intValue == -32022)
        let data = response.body?["error"]?["data"]
        #expect(data?["requested"]?.stringValue?.count == 195) // 192 + "..."
        #expect(data?["supported"]?.arrayValue?.count == MCPSupportedProtocolVersions.count)
    }

    @Test("empty version header is a mismatch, not an unsupported version")
    func emptyHeaderRejectedAsMismatch() async {
        let response = await mcpHandleRPC(
            headers: [
                "mcp-protocol-version": "",
                "mcp-method": "ping",
            ],
            body: body(method: "ping"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(response.status == 400)
        #expect(response.body?["error"]?["code"]?.intValue == -32020)
    }

    // MARK: Header/body agreement

    @Test("method header mismatch is rejected with -32020")
    func methodMismatchRejected() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "tools/list"),
            body: body(method: "tools/call"),
            toolRecorder: recorded
        )
        #expect(response.status == 400)
        #expect(response.body?["error"]?["code"]?.intValue == -32020)
        #expect(recorded.calls.isEmpty)
    }

    @Test("missing method header counts as mismatch")
    func missingMethodHeaderRejected() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: ["mcp-protocol-version": "2026-07-28"],
            body: body(method: "ping"),
            toolRecorder: recorded
        )
        #expect(response.status == 400)
        #expect(recorded.calls.isEmpty)
    }

    @Test("base64-encoded header values decode before comparison")
    func base64HeaderValueDecodes() async {
        let encoded = Data("ping".utf8).base64EncodedString()
        let response = await mcpHandleRPC(
            headers: [
                "mcp-protocol-version": "2026-07-28",
                "mcp-method": "=?base64?\(encoded)?=",
            ],
            body: body(method: "ping"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(response.status == 200)
    }

    @Test("invalid base64 header value is a mismatch")
    func invalidBase64HeaderRejected() async {
        let response = await mcpHandleRPC(
            headers: [
                "mcp-protocol-version": "2026-07-28",
                // Length % 4 == 1 is never valid.
                "mcp-method": "=?base64?AAAAA?=",
            ],
            body: body(method: "ping"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(response.body?["error"]?["code"]?.intValue == -32020)
    }

    @Test("name header mismatch on tools/call is rejected with -32020")
    func nameMismatchRejected() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "tools/call", name: "list_meetings"),
            body: body(
                method: "tools/call",
                params: .object([
                    "name": "search_meetings",
                    "arguments": .object([:]),
                ])
            ),
            toolRecorder: recorded
        )
        #expect(response.status == 400)
        #expect(response.body?["error"]?["code"]?.intValue == -32020)
        #expect(recorded.calls.isEmpty)
    }

    @Test("matching name header lets tools/call through")
    func matchingNameHeaderAccepted() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "tools/call", name: "list_meetings"),
            body: body(
                method: "tools/call",
                params: .object([
                    "name": "list_meetings",
                    "arguments": .object([:]),
                ])
            ),
            toolRecorder: recorded
        )
        #expect(response.status == 200)
        #expect(recorded.calls.count == 1)
        #expect(recorded.calls.first?.0 == "list_meetings")
    }
    // MARK: Methods

    @Test("server/discover carries resultType only on the modern version")
    func discoverResultTypeModernOnly() async {
        let recorded = ToolRecorder()
        let modern = await call(
            headers: modernHeaders(method: "server/discover"),
            body: body(method: "server/discover"),
            toolRecorder: recorded
        )
        #expect(modern.status == 200)
        #expect(modern.body?["result"]?["resultType"]?.stringValue == "complete")
        #expect(modern.body?["result"]?["capabilities"]?["tools"] != nil)
        #expect(modern.body?["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?
            .stringValue == "steno")

        let older = await mcpHandleRPC(
            headers: [
                "mcp-protocol-version": "2025-03-26",
                "mcp-method": "server/discover",
            ],
            body: body(method: "server/discover"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: ["name": "steno"]
        )
        #expect(older.body?["result"]?["resultType"] == nil)
        #expect(older.body?["result"]?["supportedVersions"] != nil)
    }

    @Test("params._meta protocol version must agree with the header")
    func metaVersionDisagreementRejected() async {
        let params: MCPJSON = .object([
            "_meta": .object(["io.modelcontextprotocol/protocolVersion": "2025-06-18"]),
        ])
        let unused = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "ping"),
            body: body(method: "ping", params: params),
            toolRecorder: unused
        )
        #expect(response.body?["error"]?["code"]?.intValue == -32020)
    }

    @Test("ping and tools/list answer 200; tools/list exposes exactly the six tools")
    func pingAndToolsList() async {
        let recorded = ToolRecorder()
        let ping = await call(
            headers: modernHeaders(method: "ping"),
            body: body(method: "ping"),
            toolRecorder: recorded
        )
        #expect(ping.status == 200)

        let list = await call(
            headers: modernHeaders(method: "tools/list"),
            body: body(method: "tools/list"),
            toolRecorder: recorded
        )
        let names = list.body?["result"]?["tools"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue } ?? []
        #expect(Set(names) == Set([
            "list_meetings", "get_meeting", "get_meeting_transcript",
            "search_meetings", "list_folders", "ask_meetings",
        ]))
    }

    @Test("unknown method answers 404 with -32601")
    func unknownMethodRejected() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "does/not-exist"),
            body: body(method: "does/not-exist"),
            toolRecorder: recorded
        )
        #expect(response.status == 404)
        #expect(response.body?["error"]?["code"]?.intValue == -32601)
    }

    @Test("unknown tool answers HTTP 200 isError instead of a transport error")
    func unknownToolIsToolLevelFailure() async {
        let recorded = ToolRecorder()
        let response = await mcpHandleRPC(
            headers: modernHeaders(method: "tools/call", name: "no_such_tool"),
            body: body(
                method: "tools/call",
                params: .object(["name": "no_such_tool", "arguments": .object([:])])
            ),
            tools: tools,
            callTool: { _, _ in
                Issue.record("callTool must not run for unknown tools")
                return MCPToolOutput.executionFailed
            },
            serverInfo: [:]
        )
        #expect(response.status == 200)
        #expect(response.body?["result"]?["isError"]?.boolValue == true)
        #expect(response.body?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ==
            "Unknown tool")
    }

    @Test("every tool result carries text content plus structuredContent")
    func toolResultShape() async {
        let response = await mcpHandleRPC(
            headers: modernHeaders(method: "tools/call", name: "list_folders"),
            body: body(
                method: "tools/call",
                params: .object(["name": "list_folders", "arguments": .object([:])])
            ),
            tools: tools,
            callTool: { _, _ in
                MCPToolOutput(text: "folders", structuredContent: .object(["folders": []]))
            },
            serverInfo: [:]
        )
        #expect(response.body?["result"]?["content"]?.arrayValue?.first?["type"]?.stringValue == "text")
        #expect(response.body?["result"]?["structuredContent"] != nil)
        #expect(response.body?["result"]?["isError"] == nil)
    }

    // MARK: Notifications

    @Test("bodies without id answer 202 with an empty body")
    func notificationAnswered202() async {
        let recorded = ToolRecorder()
        let response = await call(
            headers: modernHeaders(method: "notifications/initialized"),
            body: body(method: "notifications/initialized", id: nil),
            toolRecorder: recorded
        )
        #expect(response == .accepted)
        #expect(recorded.calls.isEmpty)

        // An explicit null id still counts as a request.
        let nullIDResponse = await call(
            headers: modernHeaders(method: "ping"),
            body: body(method: "ping", id: .null),
            toolRecorder: recorded
        )
        #expect(nullIDResponse.status == 200)
    }

    // MARK: Legacy era

    @Test("absent version header selects the legacy path with initialize negotiation")
    func legacyPathInitialize() async {
        let negotiated = await mcpHandleRPC(
            headers: [:],
            body: body(
                method: "initialize",
                params: .object(["protocolVersion": "2025-11-25"])
            ),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: ["name": "steno"]
        )
        #expect(negotiated.status == 200)
        #expect(negotiated.body?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")

        // Unsupported declarations negotiate down to the modern version.
        let fallback = await mcpHandleRPC(
            headers: [:],
            body: body(
                method: "initialize",
                params: .object(["protocolVersion": "1999-01-01"])
            ),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(fallback.body?["result"]?["protocolVersion"]?.stringValue == MCPModernProtocolVersion)

        // Unknown legacy methods stay 404.
        let unknown = await mcpHandleRPC(
            headers: [:],
            body: body(method: "resources/list"),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(unknown.status == 404)
        #expect(unknown.body?["error"]?["code"]?.intValue == -32601)
    }

    @Test("non-object bodies are invalid requests")
    func nonObjectBodyRejected() async {
        let response = await mcpHandleRPC(
            headers: [:],
            body: .array([]),
            tools: [],
            callTool: { _, _ in MCPToolOutput(text: "", structuredContent: .null) },
            serverInfo: [:]
        )
        #expect(response.status == 400)
        #expect(response.body?["error"]?["code"]?.intValue == -32600)
    }
}

/// Minimal facade stub for protocol-level tests; no behavior asserted here.
private struct StubFacade: MCPMeetingFacade {
    func listMeetings(limit _: Int) async throws -> [MCPMeetingSummary] { [] }
    func getMeeting(meetingID _: String) async throws -> MCPMeetingDetail {
        MCPMeetingDetail(
            summary: MCPMeetingSummary(
                id: "x", title: "x", date: "",
                durationSeconds: nil, folders: [], attendees: []
            ),
            reportMarkdown: "", keyPoints: [], actionItems: [], userNotes: nil
        )
    }
    func getTranscript(meetingID _: String) async throws -> (title: String, text: String) {
        ("x", "")
    }
    func search(query _: String, limit _: Int) async throws -> [MCPSearchHit] { [] }
    func folders() async throws -> [MCPFolderInfo] { [] }
    func ask(question _: String, meetingIDs _: [String]?, folderID _: String?) async throws -> String {
        ""
    }
}
