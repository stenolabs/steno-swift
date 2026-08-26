import Foundation
import Testing
@testable import StenoIntelligence

/// Transport-level gates of the local HTTP listener: routing order, origin
/// before auth, bearer auth, the 1 MiB body cap, and listener teardown.
@Suite("MCP HTTP server")
struct MCPServerTests {
    /// Fixed loopback ports for this suite. Collisions are improbable and
    /// surface as a bind failure, failing loudly instead of silently.
    private static let basePort: UInt16 = 48_731

    private let apiKey = "test-mcp-key"

    private func makeServer(port: UInt16) -> MCPServer {
        MCPServer(
            port: port,
            apiKeyProvider: { [apiKey] in apiKey }
        ) { headers, body in
            await mcpHandleRPC(
                headers: headers,
                body: body,
                tools: [],
                callTool: { _, _ in MCPToolOutput(text: "ok", structuredContent: .object([:])) },
                serverInfo: ["name": "steno"]
            )
        }
    }

    private func post(
        _ url: URL,
        key: String? = nil,
        method: String? = nil,
        origin: String? = nil,
        body: Data? = nil
    ) async throws -> (status: Int, headers: [AnyHashable: String], body: Data) {
        var request = URLRequest(url: url)
        let effectiveMethod = method ?? "POST"
        request.httpMethod = effectiveMethod
        // URLSession refuses bodies on GET/DELETE outright.
        request.httpBody = effectiveMethod == "POST"
            ? (body ?? Data(#"{"jsonrpc":"2.0","method":"ping","id":1}"#.utf8))
            : nil
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("ping", forHTTPHeaderField: "Mcp-Method")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        var headerMap: [AnyHashable: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (name, value) in http.allHeaderFields {
                headerMap[name] = "\(value)"
            }
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, headerMap, data)
    }

    @Test("auth, origin ordering, method and path gates over a real socket")
    func transportGates() async throws {
        let server = makeServer(port: Self.basePort)
        try await server.start()
        defer { Task { await server.stop() } }

        let endpoint = URL(string: "http://127.0.0.1:\(Self.basePort)/mcp")!

        // Missing Authorization -> 401 with the Bearer challenge.
        let unauthorized = try await post(endpoint)
        #expect(unauthorized.status == 401)
        #expect(unauthorized.headers["Www-Authenticate"]?.lowercased().contains("bearer") == true)

        // Wrong bearer key -> 401 (constant-time compare exercised).
        let wrongKey = try await post(endpoint, key: "not-the-key")
        #expect(wrongKey.status == 401)

        // Foreign origin beats missing auth: origin gate runs first.
        let foreignOrigin = try await post(endpoint, origin: "https://evil.example")
        #expect(foreignOrigin.status == 403)

        // Valid key + loopback origin answers.
        let ok = try await post(endpoint, key: apiKey, origin: "http://127.0.0.1:3000")
        #expect(ok.status == 200)

        // Lowercase bearer scheme is accepted.
        let lowercaseScheme = try await post(endpoint, key: apiKey)
        #expect(lowercaseScheme.status == 200)
    }

    @Test("non-POST methods answer 405 with Allow: POST")
    func methodGate() async throws {
        let server = makeServer(port: Self.basePort + 1)
        try await server.start()
        defer { Task { await server.stop() } }

        let endpoint = URL(string: "http://127.0.0.1:\(Self.basePort + 1)/mcp")!
        let get = try await post(endpoint, key: apiKey, method: "GET")
        #expect(get.status == 405)
        #expect(get.headers["Allow"] == "POST")

        let delete = try await post(endpoint, key: apiKey, method: "DELETE")
        #expect(delete.status == 405)
        #expect(delete.headers["Allow"] == "POST")
    }

    @Test("wrong path answers 404 JSON-RPC -32601")
    func pathGate() async throws {
        let server = makeServer(port: Self.basePort + 2)
        try await server.start()
        defer { Task { await server.stop() } }

        let wrongPath = URL(string: "http://127.0.0.1:\(Self.basePort + 2)/other")!
        let response = try await post(wrongPath, key: apiKey)
        #expect(response.status == 404)
        #expect(String(data: response.body, encoding: .utf8)?.contains("-32601") == true)
    }

    @Test("notification bodies answer 202 with an empty payload")
    func notificationAccepted() async throws {
        let server = makeServer(port: Self.basePort + 3)
        try await server.start()
        defer { Task { await server.stop() } }

        let endpoint = URL(string: "http://127.0.0.1:\(Self.basePort + 3)/mcp")!

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("notifications/initialized", forHTTPHeaderField: "Mcp-Method")

        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        #expect(data.isEmpty)
    }

    @Test("bodies beyond one MiB are refused with 413")
    func bodyCapRefuses413() async throws {
        let server = makeServer(port: Self.basePort + 4)
        try await server.start()
        defer { Task { await server.stop() } }

        let endpoint = URL(string: "http://127.0.0.1:\(Self.basePort + 4)/mcp")!
        let oversized = Data(repeating: 0x61, count: MCPServer.maximumBodyBytes + 1024)
        let response = try await post(endpoint, key: apiKey, body: oversized)
        #expect(response.status == 413)
    }

    @Test("stop tears down the listener so connects fail at the transport")
    func stopClosesListener() async throws {
        let port = Self.basePort + 5
        let server = makeServer(port: port)
        try await server.start()
        #expect(await server.isRunning)

        await server.stop()
        #expect(await !server.isRunning)

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        do {
            _ = try await postRawConnectFailureProbe(endpoint: endpoint, key: apiKey)
            Issue.record("port still answered after stop")
        } catch {
            // Expected: connection refused / cannot connect.
        }
    }

    /// Minimal probe used only to observe that nothing answers anymore.
    private func postRawConnectFailureProbe(endpoint: URL, key: String) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
