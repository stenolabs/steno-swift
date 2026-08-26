import CryptoKit
import Foundation
import Network

// MARK: - Request gates (transport level)

/// Validates the `Origin` header. Requests without an origin are allowed;
/// browsers always send one, so a foreign origin is the DNS-rebinding
/// fingerprint this check exists for. Only loopback origins qualify.
func mcpIsValidOrigin(_ originHeader: String?) -> Bool {
    guard let originHeader, !originHeader.isEmpty else { return true }
    guard let url = URL(string: originHeader),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host(percentEncoded: false)?.lowercased()
    else {
        return false
    }
    return host == "127.0.0.1" || host == "localhost"
}

/// Constant-time string comparison: both sides are hashed with SHA-256 and
/// the fixed-size digests are compared in constant time, so neither digest
/// nor length of the expected key leaks through timing.
func mcpSafeCompareStrings(_ a: String, _ b: String) -> Bool {
    let hashA = SHA256.hash(data: Data(a.utf8))
    let hashB = SHA256.hash(data: Data(b.utf8))
    var difference: UInt8 = 0
    for (left, right) in zip(hashA, hashB) {
        difference |= left ^ right
    }
    return difference == 0
}

/// Extracts the bearer token from an `Authorization` header. The scheme is
/// matched case-insensitively, mirroring how real clients emit it.
func mcpBearerToken(from authorizationHeader: String?) -> String? {
    guard let authorizationHeader else { return nil }
    let prefix = "bearer "
    guard authorizationHeader.count > prefix.count,
          authorizationHeader.lowercased().hasPrefix(prefix)
    else {
        return nil
    }
    let token = String(authorizationHeader.dropFirst(prefix.count))
    return token.isEmpty ? nil : token
}

// MARK: - Parsed request

/// One fully received HTTP/1.1 request on the MCP listener.
struct MCPRawRequest: Sendable {
    var method: String
    /// Request target exactly as sent, including any query string.
    var target: String
    /// Header map with lower-cased keys; duplicate names join with ", ".
    var headers: [String: String]
    var body: Data

    /// Parses the header block of one request. Returns nil when the request
    /// line is unusable.
    init?(headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        self.init(
            method: String(parts[0]),
            target: String(parts[1]),
            headers: headers,
            body: Data()
        )
    }

    init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

extension MCPJSON {
    /// Decodes wire bytes into the closed JSON model.
    static func decode(_ data: Data) throws -> MCPJSON {
        try JSONDecoder().decode(MCPJSON.self, from: data)
    }

    /// Encodes the closed JSON model to compact wire bytes.
    static func encode(_ value: MCPJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

// MARK: - Server

/// Local HTTP server exposing the MCP JSON-RPC surface.
///
/// Security posture, in evaluation order per request:
/// 1. Bound to `127.0.0.1` only - never any external interface.
/// 2. Single path `/mcp`, POST-only (`GET`/`DELETE` -> 405 + `Allow: POST`,
///    anything else -> 404 JSON-RPC -32601).
/// 3. Origin gate BEFORE auth (foreign origin -> 403 -32000).
/// 4. Bearer key required (constant-time compare; missing/wrong -> 401
///    -32000 + `WWW-Authenticate: Bearer`).
/// 5. Body cap of 1 MiB (exceeded -> 413 -32000).
///
/// Each connection serves exactly one request; responses are sent with
/// `Connection: close`. Disabling cancels the listener, after which a TCP
/// connect fails at the transport instead of receiving any status.
public actor MCPServer {
    /// Maximum accepted request body size: 1 MiB.
    public static let maximumBodyBytes = 1_048_576

    private let configuredPort: UInt16
    private let apiKeyProvider: @Sendable () -> String?
    private let rpcHandler: @Sendable ([String: String], MCPJSON) async -> MCPHTTPResponse

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    public private(set) var running = false
    public private(set) var boundPort: UInt16?

    nonisolated static let queue = DispatchQueue(label: "net.steno.mcp-server")

    public init(
        port: UInt16,
        apiKeyProvider: @escaping @Sendable () -> String?,
        rpcHandler: @escaping @Sendable ([String: String], MCPJSON) async -> MCPHTTPResponse
    ) {
        configuredPort = port
        self.apiKeyProvider = apiKeyProvider
        self.rpcHandler = rpcHandler
    }

    /// Whether the listener currently answers on `/mcp`.
    public var isRunning: Bool { running }

    // MARK: Lifecycle


    /// Upper bound for post-response draining: comfortably more than the
    /// body cap so a refused upload can finish before the close.
    static let maximumDrainBytes = 8 * 1_048_576
    /// Starts listening on the configured port, loopback only. Throws when
    /// the port cannot be bound (for example a collision).
    public func start() async throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: configuredPort) else {
            throw MCPServerError.invalidPort(configuredPort)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        // The bound endpoint carries the port; passing a port here as well
        // makes Network reject the parameters outright.
        let newListener = try NWListener(using: parameters)
        let readiness = AsyncStream<NWListener.State> { continuation in
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    continuation.yield(state)
                    continuation.finish()
                default:
                    break
                }
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        self.listener = newListener
        newListener.start(queue: Self.queue)

        var observedState: NWListener.State = .setup
        for await state in readiness {
            observedState = state
            break
        }
        switch observedState {
        case .ready:
            running = true
            boundPort = configuredPort
        case .failed(let error):
            self.listener = nil
            throw MCPServerError.bindFailed(error)
        default:
            self.listener = nil
            throw MCPServerError.bindFailed(NWError.posix(.EINVAL))
        }
    }

    /// Stops listening and tears down every open connection. Afterwards a
    /// TCP connect to the port fails instead of being answered.
    public func stop() {
        guard listener != nil || running else { return }
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        running = false
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: Self.queue)
        Task { await serve(connection) }
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    // MARK: Per-connection serving

    private func serve(_ connection: NWConnection) async {
        defer { finish(connection) }
        let outcome: ReadOutcome
        do {
            outcome = try await readRequest(connection)
        } catch {
            // Client went away or sent garbage; close without a response.
            return
        }

        // After every response we keep draining until the client closes the
        // connection: with `Connection: close` an early cancel could cut the
        // response short mid-flush, and a refused oversized upload would
        // never see the 413 at all.
        switch outcome {
        case .request(let request):
            let response = await route(request)
            try? await send(response, on: connection)
            await drain(connection, limit: Self.maximumDrainBytes)
        case .payloadTooLarge:
            // The 413 was already sent inside `readRequest`.
            await drain(connection, limit: Self.maximumDrainBytes)
        }
    }

    /// Discards inbound bytes until EOF or the cap; keeps uploads from
    /// wedging when the answer is already decided.
    private func drain(_ connection: NWConnection, limit: Int) async {
        var discarded = 0
        while discarded < limit {
            guard let chunk = try? await receiveChunk(connection), !chunk.isEmpty else {
                return
            }
            discarded += chunk.count
        }
    }

    private enum ReadOutcome {
        case request(MCPRawRequest)
        case payloadTooLarge
    }

    /// Reads one complete request or short-circuits with the 413 answer.
    private func readRequest(_ connection: NWConnection) async throws -> ReadOutcome {
        var buffer = Data()

        while true {
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                var bodyData = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)

                guard var request = MCPRawRequest(headerData: headerData) else {
                    return .request(MCPRawRequest(
                        method: "POST", target: "/mcp", headers: [:], body: Data()
                    ))
                }

                let contentLength = request.headers["content-length"].flatMap { Int($0) } ?? 0
                if request.method.uppercased() == "POST",
                   max(contentLength, bodyData.count) > Self.maximumBodyBytes
                {
                    try await send(Self.payloadTooLargeResponse, on: connection)
                    return .payloadTooLarge
                }

                // Drain the declared body length.
                while bodyData.count < contentLength {
                    guard let chunk = try await receiveChunk(connection) else { break }
                    bodyData.append(chunk)
                    if bodyData.count > Self.maximumBodyBytes {
                        try await send(Self.payloadTooLargeResponse, on: connection)
                        return .payloadTooLarge
                    }
                }

                request.body = bodyData.prefix(contentLength)
                return .request(request)
            }

            if buffer.count > Self.maximumBodyBytes + 65_536 {
                // Header block itself is absurd; refuse without reading more.
                try await send(Self.payloadTooLargeResponse, on: connection)
                return .payloadTooLarge
            }

            guard let chunk = try await receiveChunk(connection) else {
                if buffer.isEmpty {
                    throw MCPServerReadError.connectionClosed
                }
                throw MCPServerReadError.truncatedRequest
            }
            buffer.append(chunk)
        }
    }

    private func receiveChunk(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isConnected, error in
                if let error {
                    continuation.resume(throwing: MCPServerReadError.receiveFailed(error))
                } else if let data {
                    continuation.resume(returning: data)
                } else if !isConnected {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: Routing and gates

    private func route(_ request: MCPRawRequest) async -> MCPHTTPResponse {
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? request.target

        // 1. Path gate.
        guard path == "/mcp" else {
            return MCPHTTPResponse(
                status: 404,
                body: mcpJSONError(id: nil, code: -32601, message: "Not Found")
            )
        }

        let method = request.method.uppercased()

        // 2. Method gate: POST only.
        guard method == "POST" else {
            return MCPHTTPResponse(
                status: 405,
                body: mcpJSONError(id: nil, code: -32601, message: "Method Not Allowed"),
                headers: ["Allow": "POST"]
            )
        }

        // 3. Origin gate BEFORE auth.
        if let origin = request.headers["origin"], !mcpIsValidOrigin(origin) {
            return MCPHTTPResponse(
                status: 403,
                body: mcpJSONError(id: nil, code: -32000, message: "Forbidden: Invalid Origin")
            )
        }

        // 4. Bearer auth gate.
        let expectedKey = apiKeyProvider()
        let providedToken = mcpBearerToken(from: request.headers["authorization"])
        let authenticated: Bool
        if let expectedKey, let providedToken {
            authenticated = mcpSafeCompareStrings(providedToken, expectedKey)
        } else {
            authenticated = false
        }
        guard authenticated else {
            return MCPHTTPResponse(
                status: 401,
                body: mcpJSONError(id: nil, code: -32000, message: "Unauthorized"),
                headers: ["WWW-Authenticate": "Bearer"]
            )
        }

        // 5. Parse the JSON body and dispatch.
        guard !request.body.isEmpty else {
            return MCPHTTPResponse(
                status: 400,
                body: mcpJSONError(id: nil, code: -32700, message: "Parse error: empty body")
            )
        }

        let parsed: MCPJSON
        do {
            parsed = try MCPJSON.decode(request.body)
        } catch {
            return MCPHTTPResponse(
                status: 400,
                body: mcpJSONError(id: nil, code: -32700, message: "Parse error")
            )
        }

        return await rpcHandler(request.headers, parsed)
    }

    static let payloadTooLargeResponse = MCPHTTPResponse(
        status: 413,
        body: mcpJSONError(id: nil, code: -32000, message: "Payload Too Large")
    )

    // MARK: Wire format

    private static let reasonPhrases: [Int: String] = [
        200: "OK",
        202: "Accepted",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        413: "Payload Too Large",
        500: "Internal Server Error",
    ]

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) async throws {
        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrases[response.status] ?? "OK")\r\n"
        var extraHeaders = response.headers
        extraHeaders["Connection"] = "close"

        let bodyData: Data
        if let body = response.body {
            bodyData = try MCPJSON.encode(body)
            extraHeaders["Content-Type"] = "application/json"
            extraHeaders["Content-Length"] = String(bodyData.count)
        } else {
            bodyData = Data()
            extraHeaders["Content-Length"] = "0"
        }
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(bodyData)
        try await sendData(payload, on: connection)
    }

    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MCPServerReadError.receiveFailed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// Transport-level failures inside the server loop.
enum MCPServerReadError: Error {
    case payloadTooLarge
    case truncatedRequest
    case connectionClosed
    case receiveFailed(NWError)
}

/// Listener lifecycle failures surfaced from `start()`.
public enum MCPServerError: Error, Equatable, Sendable {
    case invalidPort(UInt16)
    case bindFailed(NWError)
}
