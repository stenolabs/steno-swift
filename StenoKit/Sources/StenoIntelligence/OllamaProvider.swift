import Foundation
import StenoDomain

public enum OllamaProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case authenticationRejected
    case modelNotFound(String)
    case serverError(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "Der Ollama-Endpunkt unter \(url.absoluteString) ist nicht erreichbar."
        case .requestTimedOut(let url):
            "Ollama unter \(url.absoluteString) hat nicht rechtzeitig geantwortet."
        case .authenticationRejected:
            "Der API-Schlüssel wurde von Ollama abgelehnt."
        case .modelNotFound(let modelID):
            "Das Modell „\(modelID)“ ist in Ollama nicht verfügbar."
        case .serverError(let statusCode):
            "Ollama hat mit HTTP \(statusCode) geantwortet."
        case .invalidResponse:
            "Ollama hat keine gültige strukturierte Antwort geliefert."
        }
    }
}

extension OllamaProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        switch self {
        case .endpointUnreachable: (status, code) = (nil, "endpoint_unreachable")
        case .requestTimedOut: (status, code) = (nil, "request_timed_out")
        case .authenticationRejected: (status, code) = (nil, "authentication_rejected")
        case .modelNotFound: (status, code) = (404, "model_not_found")
        case .serverError(let statusCode): (status, code) = (statusCode, "server_error")
        case .invalidResponse: (status, code) = (nil, "invalid_response")
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.ollama.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            parsingFailure: code == "invalid_response" ? "structured_response" : nil
        )
    }
}

public struct OllamaProvider: StructuredTextModelProvider {
    public let descriptor: EngineDescriptor
    public let availability: TextModelAvailability = .available

    private let endpoint: TextModelEndpoint
    private let resolvingSecret: TextModelSecretResolving
    private let client: TextModelHTTPClient

    public init(
        endpoint: TextModelEndpoint,
        resolvingSecret: @escaping TextModelSecretResolving = { _ in nil },
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.endpoint = endpoint
        self.resolvingSecret = resolvingSecret
        self.client = TextModelHTTPClient(sessionConfiguration: sessionConfiguration)
        self.descriptor = EngineDescriptor(
            name: endpoint.name,
            version: "ollama-native",
            modelVersion: endpoint.modelID
        )
    }

    public var contextWindow: TextModelContextWindow {
        // Der eingetragene Wert gilt, wie er eingetragen ist. Frueher deckelte
        // ein `hosting == .selfHosted` ihn auf 32K, doch `hosting` sagt, wo ein
        // Server steht, nicht wie gross sein Fenster ist: ein Ollama im eigenen
        // Netz gilt als `.cloud` und entkam der Deckelung, ein Loopback-Server
        // bekam sie. Solange das Feld gar nicht einstellbar war, trug jeder
        // Endpunkt den Standard von 4096 und die Deckelung lief leer. Jetzt ist
        // der Wert eine bewusste Angabe des Nutzers, und still etwas anderes zu
        // verwenden waere schlimmer als jede Grenze.
        let maximumTokens = endpoint.contextWindowTokens
        return TextModelContextWindow(
            maximumTokens: maximumTokens,
            reservedResponseTokens: min(4_096, max(1_024, maximumTokens / 8)),
            safetyTokens: 128
        )
    }

    public func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        let body = requestBody(
            template: template,
            request: request,
            context: context,
            includesThink: true
        )
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return max(1, (data.count + 1) / 2)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        var result = try await completion(
            template: template,
            request: request,
            context: context,
            includesThink: true
        )
        if result.response.statusCode == 400,
           Self.isThinkUnsupported(result.data)
        {
            try Task.checkCancellation()
            result = try await completion(
                template: template,
                request: request,
                context: context,
                includesThink: false
            )
        }
        guard (200..<300).contains(result.response.statusCode) else {
            throw mappedHTTPError(result.response.statusCode)
        }
        let response: ChatResponse
        do {
            response = try JSONDecoder().decode(ChatResponse.self, from: result.data)
        } catch {
            throw OllamaProviderError.invalidResponse
        }
        // Auch hier, obwohl dieser Provider `think: false` setzt: lehnt ein
        // Server den Schalter ab, faellt `generate` auf einen Aufruf ohne ihn
        // zurueck, und dann kann das Budget wieder in den Gedanken landen.
        if response.doneReason == "length" {
            throw response.message.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                ? TextModelProviderError.responseEmpty
                : TextModelProviderError.responseTruncated
        }
        do {
            return try StructuredTemplateCodec.decode(
                Data(response.message.content.utf8),
                template: template
            )
        } catch {
            throw OllamaProviderError.invalidResponse
        }
    }

    public func probe() async throws -> TextModelProbeResult {
        let start = ContinuousClock.now
        let tags = try await modelList()
        let available = tags.contains(endpoint.modelID)
        guard available else {
            return TextModelProbeResult(
                isReachable: true,
                isModelAvailable: false,
                configuredContextWindowTokens: endpoint.contextWindowTokens
            )
        }
        _ = try await generate(
            template: .meetingMinutes,
            request: .map(TranscriptChunk(turns: [
                TranscriptChunkTurn(
                    speakerName: "Speaker 1",
                    start: 0,
                    end: 1,
                    text: "Synthetic connection test."
                ),
            ])),
            context: RenderContext()
        )
        let elapsed = start.duration(to: .now)
        return TextModelProbeResult(
            isReachable: true,
            isModelAvailable: true,
            supportsStructuredGeneration: true,
            configuredContextWindowTokens: endpoint.contextWindowTokens,
            durationMilliseconds: Self.milliseconds(elapsed)
        )
    }

    private func completion(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesThink: Bool
    ) async throws -> TextModelHTTPResponse {
        var urlRequest = URLRequest(
            url: Self.nativeRoot(endpoint.baseURL).appendingPathComponent("api/chat"),
            timeoutInterval: 600
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try addAuthorization(to: &urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            template: template,
            request: request,
            context: context,
            includesThink: includesThink
        ))
        return try await send(urlRequest)
    }

    private func modelList() async throws -> Set<String> {
        var request = URLRequest(
            url: Self.nativeRoot(endpoint.baseURL).appendingPathComponent("api/tags"),
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try addAuthorization(to: &request)
        let result = try await send(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw mappedHTTPError(result.response.statusCode)
        }
        do {
            let response = try JSONDecoder().decode(TagsResponse.self, from: result.data)
            return Set(response.models.flatMap { [$0.name, $0.model].compactMap { $0 } })
        } catch {
            throw OllamaProviderError.invalidResponse
        }
    }

    private func requestBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesThink: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.modelID,
            "stream": false,
            "format": StructuredTemplateCodec.schema(for: template),
            "options": [
                "temperature": 0,
                "num_ctx": contextWindow.maximumTokens,
                "num_predict": contextWindow.reservedResponseTokens,
            ],
            "messages": [
                [
                    "role": "system",
                    "content": StructuredTemplatePrompt.instructions(for: template, context: context),
                ],
                [
                    "role": "user",
                    "content": StructuredTemplatePrompt.prompt(
                        for: request,
                        template: template,
                        context: context
                    ),
                ],
            ],
        ]
        if includesThink {
            body["think"] = false
        }
        return body
    }

    private func send(_ request: URLRequest) async throws -> TextModelHTTPResponse {
        do {
            return try await client.send(request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut {
                throw OllamaProviderError.requestTimedOut(
                    TextModelHTTPClient.safeEndpointURL(endpoint.baseURL)
                )
            }
            throw OllamaProviderError.endpointUnreachable(
                TextModelHTTPClient.safeEndpointURL(endpoint.baseURL)
            )
        }
    }

    private func addAuthorization(to request: inout URLRequest) throws {
        if let secret = try resolvingSecret(endpoint.id) {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
    }

    private func mappedHTTPError(_ statusCode: Int) -> OllamaProviderError {
        switch statusCode {
        case 401, 403:
            .authenticationRejected
        case 404:
            .modelNotFound(endpoint.modelID)
        default:
            .serverError(statusCode: statusCode)
        }
    }

    static func nativeRoot(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var path = components.percentEncodedPath
        if path.hasSuffix("/v1/") {
            path.removeLast(4)
        } else if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.percentEncodedPath = path
        return components.url ?? url
    }

    private static func isThinkUnsupported(_ data: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        else { return false }
        let message = response.error.lowercased()
        return message.contains("think")
            && (message.contains("unknown") || message.contains("unsupported"))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct TagsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String?
        let model: String?
    }
}

private struct ChatResponse: Decodable {
    let message: Message
    let doneReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case doneReason = "done_reason"
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}
