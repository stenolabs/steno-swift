import Foundation

// MARK: - JSON value model

/// A closed JSON representation used across the MCP surface. The protocol
/// responses have dynamic shapes (results, errors, `_meta` maps), so a typed
/// enum keeps every layer `Sendable`, `Equatable`, and deterministic to
/// compare in tests - no `JSONSerialization` bags of `Any`.
public enum MCPJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])
}

extension MCPJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Must precede the number branch: JSONDecoder decodes `true` as
            // Bool only when asked first.
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MCPJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension MCPJSON: ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral,
    ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral _: ()) { self = .null }
    public init(arrayLiteral elements: MCPJSON...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, MCPJSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension MCPJSON {
    /// Object payload when this value is an object, otherwise nil.
    public var objectValue: [String: MCPJSON]? {
        if case .object(let dictionary) = self { return dictionary }
        return nil
    }

    /// Array payload when this value is an array, otherwise nil.
    public var arrayValue: [MCPJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// String payload when this value is a string, otherwise nil.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Integral payload when this value is a number that is exactly integral.
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    /// Boolean payload when this value is a boolean, otherwise nil.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Subscript-style lookup into an object payload; missing key or
    /// non-object receiver yields nil.
    public subscript(key: String) -> MCPJSON? {
        objectValue?[key]
    }
}

// MARK: - Protocol constants

/// Protocol versions this server understands, newest first.
public let MCPSupportedProtocolVersions: [String] = [
    "2026-07-28",
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
]

/// The newest protocol version; only it carries `resultType: "complete"`.
public let MCPModernProtocolVersion = "2026-07-28"

/// Header that declares the client's protocol version. Its absence selects
/// the legacy era where no header metadata is validated.
let MCPProtocolVersionHeaderName = "mcp-protocol-version"
/// Anti-DNS-rebinding headers: both must mirror the parsed JSON-RPC body.
let MCPMethodHeaderName = "mcp-method"
let MCPNameHeaderName = "mcp-name"

// MARK: - Response envelope

/// One complete HTTP answer produced by the RPC dispatcher.
public struct MCPHTTPResponse: Equatable, Sendable {
    public let status: Int
    /// JSON body; `nil` sends an empty body (notifications).
    public let body: MCPJSON?
    /// Extra headers such as `Allow` or `WWW-Authenticate`.
    public let headers: [String: String]

    public init(status: Int, body: MCPJSON?, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// Notification outcome: HTTP 202 with an intentionally empty body.
    public static let accepted = MCPHTTPResponse(status: 202, body: nil)
}

// MARK: - Helpers

/// Builds a JSON-RPC error envelope. A missing id degrades to `null`.
func mcpJSONError(id: MCPJSON?, code: Int, message: String, data: MCPJSON? = nil) -> MCPJSON {
    var error: [String: MCPJSON] = [
        "code": .number(Double(code)),
        "message": .string(message),
    ]
    if let data {
        error["data"] = data
    }
    return .object([
        "jsonrpc": "2.0",
        "id": id ?? .null,
        "error": .object(error),
    ])
}
/// True when the body carries no explicit `id` member. JSON-RPC treats the
/// absence of `id` as a notification, which never receives a response body.
/// An explicit `"id": null` still counts as a request.
func mcpIsNotification(_ body: MCPJSON) -> Bool {
    guard let object = body.objectValue else { return true }
    return !object.keys.contains("id")
}
func mcpResponseResult(
    id: MCPJSON?,
    result: [String: MCPJSON],
    includeResultType: Bool
) -> MCPJSON {
    var payload = result
    if includeResultType {
        payload["resultType"] = "complete"
    }
    return .object([
        "jsonrpc": "2.0",
        "id": id ?? .null,
        "result": .object(payload),
    ])
}

/// Truncates echoable user input so hostile oversized strings cannot bounce
/// back in error payloads verbatim.
func mcpTruncate(_ value: String, max: Int = 192) -> String {
    guard value.count > max else { return value }
    return String(value.prefix(max)) + "..."
}

/// Decodes RFC 2047-style `=?base64?<token>?=` header values. Anything else
/// passes through unchanged; a malformed token throws and the caller turns
/// that into a header-mismatch rejection.
func mcpDecodeHeaderValue(_ raw: String) throws -> String {
    guard raw.hasPrefix("=?base64?"), raw.hasSuffix("?="), raw.count >= 11 else {
        return raw
    }
    let token = String(raw.dropFirst("=?base64?".count).dropLast("?=".count))
    // Length % 4 == 1 is never valid base64.
    guard token.count % 4 != 1 else {
        throw MCPPHeaderDecodingError()
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        throw MCPPHeaderDecodingError()
    }
    guard let data = Data(base64Encoded: token),
          let decoded = String(data: data, encoding: .utf8)
    else {
        throw MCPPHeaderDecodingError()
    }
    return decoded
}

/// Thrown for syntactically invalid encoded header values.
struct MCPPHeaderDecodingError: Error {}


/// Reads a single-valued string header from the lower-cased header map.
/// Array-shaped or non-string values are rejected (they collapse to nil).
func mcpGetHeader(_ headers: [String: String], name: String) -> String? {
    headers[name]
}

// MARK: - Dispatcher

/// Pure JSON-RPC 2.0 dispatcher for the MCP surface.
///
/// Transport-independent by design: the HTTP server performs routing, origin
/// and bearer-auth gates first, then hands the parsed body here together
/// with the (lower-cased) header map.
///
/// - Parameters:
///   - headers: Lower-cased request headers.
///   - body: Parsed JSON body.
///   - tools: Advertised tool definitions (`tools/list`).
///   - callTool: Executes one named tool call.
///   - serverInfo: Server identity echoed in `server/discover`.
public func mcpHandleRPC(
    headers: [String: String],
    body: MCPJSON,
    tools: [MCPToolDefinition],
    callTool: @escaping @Sendable (String, MCPJSON) async -> MCPToolOutput,
    serverInfo: [String: MCPJSON]
) async -> MCPHTTPResponse {
    guard body.objectValue != nil else {
        return MCPHTTPResponse(
            status: 400,
            body: mcpJSONError(id: nil, code: -32600, message: "Invalid Request")
        )
    }

    let requestID = body["id"]
    let method = body["method"]?.stringValue

    // Modern era: the version header opts the client into strict metadata
    // validation. Its absence selects the legacy era below.
    guard let protocolVersionHeader = headers[MCPProtocolVersionHeaderName] else {
        return mcpHandleLegacyRPC(body: body, serverInfo: serverInfo)
    }

    guard !protocolVersionHeader.isEmpty else {
        return MCPHTTPResponse(
            status: 400,
            body: mcpJSONError(
                id: requestID,
                code: -32020,
                message: "Header mismatch for MCP-Protocol-Version"
            )
        )
    }

    guard MCPSupportedProtocolVersions.contains(protocolVersionHeader) else {
        return MCPHTTPResponse(
            status: 400,
            body: mcpJSONError(
                id: requestID,
                code: -32022,
                message: "Unsupported MCP protocol version",
                data: .object([
                    "supported": .array(MCPSupportedProtocolVersions.map(MCPJSON.string)),
                    "requested": .string(mcpTruncate(protocolVersionHeader)),
                ])
            )
        )
    }

    // Anti-DNS-rebinding: the Mcp-Method header must mirror the body method.
    let headerMethod: String?
    do {
        headerMethod = try headers[MCPMethodHeaderName].map(mcpDecodeHeaderValue)
    } catch {
        headerMethod = nil
    }
    guard let headerMethod, let method, headerMethod == method else {
        return MCPHTTPResponse(
            status: 400,
            body: mcpJSONError(
                id: requestID,
                code: -32020,
                message: "Header mismatch for Mcp-Method"
            )
        )
    }

    // Tool calls additionally pin the tool name in a header.
    if method == "tools/call" {
        let headerName: String?
        do {
            headerName = try headers[MCPNameHeaderName].map(mcpDecodeHeaderValue)
        } catch {
            headerName = nil
        }
        let declaredName = body["params"]?["name"]?.stringValue
        guard let headerName, let declaredName, headerName == declaredName else {
            return MCPHTTPResponse(
                status: 400,
                body: mcpJSONError(
                    id: requestID,
                    code: -32020,
                    message: "Header mismatch for Mcp-Name"
                )
            )
        }
    }

    // Body-declared protocol version must agree with the header.
    if case .object(let params)? = body["params"],
       case .object(let meta)? = params["_meta"],
       case .string(let metaVersion)? = meta["io.modelcontextprotocol/protocolVersion"],
       metaVersion != protocolVersionHeader
    {
        return MCPHTTPResponse(
            status: 400,
            body: mcpJSONError(
                id: requestID,
                code: -32020,
                message: "Header mismatch for MCP-Protocol-Version with body params._meta"
            )
        )
    }

    if mcpIsNotification(body) {
        return .accepted
    }

    // Only the newest version stamps result envelopes as complete.
    let includeResultType = protocolVersionHeader == MCPModernProtocolVersion

    switch method {
    case "server/discover":
        return MCPHTTPResponse(
            status: 200,
            body: mcpResponseResult(
                id: requestID,
                result: [
                    "supportedVersions": .array(MCPSupportedProtocolVersions.map(MCPJSON.string)),
                    "capabilities": .object(["tools": .object([:])]),
                    "_meta": .object([
                        "io.modelcontextprotocol/serverInfo": .object(serverInfo),
                    ]),
                ],
                includeResultType: includeResultType
            )
        )

    case "tools/list":
        let listed: [MCPJSON] = tools.map { definition in
            .object([
                "name": .string(definition.name),
                "title": .string(definition.title),
                "description": .string(definition.description),
                "inputSchema": definition.inputSchema,
            ])
        }
        return MCPHTTPResponse(
            status: 200,
            body: mcpResponseResult(
                id: requestID,
                result: ["tools": .array(listed)],
                includeResultType: includeResultType
            )
        )

    case "ping":
        return MCPHTTPResponse(
            status: 200,
            body: mcpResponseResult(id: requestID, result: [:], includeResultType: includeResultType)
        )

    case "tools/call":
        let toolName = body["params"]?["name"]?.stringValue
        guard let toolName, tools.contains(where: { $0.name == toolName }) else {
            // Unknown tools stay a tool-level failure (HTTP 200 + isError) so
            // transports that always answer 200 keep working.
            return MCPHTTPResponse(
                status: 200,
                body: mcpResponseResult(
                    id: requestID,
                    result: MCPToolOutput.unknownTool.payloadDictionary(),
                    includeResultType: false
                )
            )
        }

        let arguments = body["params"]?["arguments"] ?? .object([:])
        let output = await callTool(toolName, arguments)
        return MCPHTTPResponse(
            status: 200,
            body: mcpResponseResult(
                id: requestID,
                result: output.payloadDictionary(),
                includeResultType: false
            )
        )

    default:
        return MCPHTTPResponse(
            status: 404,
            body: mcpJSONError(id: requestID, code: -32601, message: "Method not found")
        )
    }
}

/// Pre-header-era behavior: notifications answered 202, `initialize`
/// negotiated a supported version, everything else unknown.
private func mcpHandleLegacyRPC(
    body: MCPJSON,
    serverInfo: [String: MCPJSON]
) -> MCPHTTPResponse {
    if mcpIsNotification(body) {
        return .accepted
    }

    let requestID = body["id"]
    let method = body["method"]?.stringValue

    if method == "initialize" {
        // Clients could declare their version in params.protocolVersion; an
        // unsupported or absent declaration negotiates down to the modern
        // version rather than failing.
        let requested = body["params"]?["protocolVersion"]?.stringValue
        let negotiated = requested.flatMap { requested in
            MCPSupportedProtocolVersions.contains(requested) ? requested : nil
        } ?? MCPModernProtocolVersion
        var result: [String: MCPJSON] = [
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object([:])]),
        ]
        if !serverInfo.isEmpty {
            result["serverInfo"] = .object(serverInfo)
        }
        return MCPHTTPResponse(
            status: 200,
            body: .object([
                "jsonrpc": "2.0",
                "id": requestID ?? .null,
                "result": .object(result),
            ])
        )
    }

    if let method, method.hasPrefix("notifications/") {
        return .accepted
    }

    return MCPHTTPResponse(
        status: 404,
        body: mcpJSONError(id: requestID, code: -32601, message: "Method not found")
    )
}
