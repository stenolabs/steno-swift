import Foundation
import StenoDomain

public enum LMStudioProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case authenticationRejected
    case modelNotFound(String)
    case modelNotLoaded(String)
    case structuredOutputUnsupported
    case serverError(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "LM Studio unter \(url.absoluteString) ist nicht erreichbar."
        case .requestTimedOut(let url):
            "LM Studio unter \(url.absoluteString) hat nicht rechtzeitig geantwortet."
        case .authenticationRejected:
            "Der API-Schlüssel wurde von LM Studio abgelehnt."
        case .modelNotFound(let modelID):
            "Das Modell „\(modelID)“ ist in LM Studio nicht verfügbar."
        case .modelNotLoaded(let modelID):
            "Das Modell „\(modelID)“ ist in LM Studio vorhanden, aber nicht geladen."
        case .structuredOutputUnsupported:
            "Das gewählte LM-Studio-Modell unterstützt die erforderliche strukturierte Ausgabe nicht."
        case .serverError(let statusCode):
            "LM Studio hat mit HTTP \(statusCode) geantwortet."
        case .invalidResponse:
            "LM Studio hat keine gültige strukturierte Antwort geliefert."
        }
    }
}

extension LMStudioProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        switch self {
        case .endpointUnreachable: (status, code) = (nil, "endpoint_unreachable")
        case .requestTimedOut: (status, code) = (nil, "request_timed_out")
        case .authenticationRejected: (status, code) = (nil, "authentication_rejected")
        case .modelNotFound: (status, code) = (404, "model_not_found")
        case .modelNotLoaded: (status, code) = (nil, "model_not_loaded")
        case .structuredOutputUnsupported: (status, code) = (nil, "structured_output_unsupported")
        case .serverError(let statusCode): (status, code) = (statusCode, "server_error")
        case .invalidResponse: (status, code) = (nil, "invalid_response")
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.lmStudio.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            parsingFailure: code == "invalid_response" ? "structured_response" : nil
        )
    }
}

public struct LMStudioProvider: StructuredTextModelProvider {
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
            version: "lmstudio-openai-chat",
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
        let data = try JSONSerialization.data(
            withJSONObject: requestBody(
                template: template,
                request: request,
                context: context
            ),
            options: [.sortedKeys]
        )
        return max(1, (data.count + 1) / 2)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let result = try await completion(
            template: template,
            request: request,
            context: context
        )
        guard (200..<300).contains(result.response.statusCode) else {
            if [400, 422].contains(result.response.statusCode),
               Self.isStructuredOutputUnsupported(result.data)
            {
                throw LMStudioProviderError.structuredOutputUnsupported
            }
            throw mappedHTTPError(result.response.statusCode)
        }
        let response: LMStudioChatResponse
        do {
            response = try JSONDecoder().decode(LMStudioChatResponse.self, from: result.data)
        } catch {
            throw LMStudioProviderError.invalidResponse
        }
        guard let choice = response.choices.first else {
            throw LMStudioProviderError.invalidResponse
        }
        // Leerer Inhalt heisst nicht "zu gross", sondern "das Budget ist
        // woanders hingegangen" - bei einem Modell mit Denkmodus in die
        // Gedanken. Teilen hilft dann nicht, siehe TextModelProviderError.
        if choice.finishReason == "length" {
            throw choice.message.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                ? TextModelProviderError.responseEmpty
                : TextModelProviderError.responseTruncated
        }
        do {
            return try StructuredTemplateCodec.decode(
                Data(choice.message.content.utf8),
                template: template
            )
        } catch {
            throw LMStudioProviderError.invalidResponse
        }
    }

    public func probe() async throws -> TextModelProbeResult {
        let start = ContinuousClock.now
        let models = try await modelList()
        guard models.contains(endpoint.modelID) else {
            return TextModelProbeResult(
                isReachable: true,
                isModelAvailable: false,
                configuredContextWindowTokens: endpoint.contextWindowTokens
            )
        }
        let metadata = try await modelMetadata()
        if let state = metadata?.state, state != "loaded" {
            throw LMStudioProviderError.modelNotLoaded(endpoint.modelID)
        }
        let reported = metadata?.maxContextLength
        if let reported, reported < endpoint.contextWindowTokens {
            return TextModelProbeResult(
                isReachable: true,
                isModelAvailable: true,
                supportsStructuredGeneration: false,
                configuredContextWindowTokens: endpoint.contextWindowTokens,
                reportedContextWindowTokens: reported,
                durationMilliseconds: Self.milliseconds(start.duration(to: .now))
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
        return TextModelProbeResult(
            isReachable: true,
            isModelAvailable: true,
            supportsStructuredGeneration: true,
            configuredContextWindowTokens: endpoint.contextWindowTokens,
            reportedContextWindowTokens: reported,
            durationMilliseconds: Self.milliseconds(start.duration(to: .now))
        )
    }

    private func completion(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> TextModelHTTPResponse {
        var urlRequest = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("chat/completions"),
            timeoutInterval: 600
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try addAuthorization(to: &urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            template: template,
            request: request,
            context: context
        ))
        return try await send(urlRequest)
    }

    private func modelList() async throws -> Set<String> {
        var request = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("models"),
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
            let response = try JSONDecoder().decode(LMStudioModelList.self, from: result.data)
            return Set(response.data.map(\.id))
        } catch {
            throw LMStudioProviderError.invalidResponse
        }
    }

    private func modelMetadata() async throws -> LMStudioModelMetadata? {
        let root = Self.nativeRoot(endpoint.baseURL)
            .appendingPathComponent("api/v0/models")
            .appendingPathComponent(endpoint.modelID)
        var request = URLRequest(url: root, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try addAuthorization(to: &request)
        let result = try await send(request)
        if result.response.statusCode == 404 { return nil }
        guard (200..<300).contains(result.response.statusCode) else {
            throw mappedHTTPError(result.response.statusCode)
        }
        do {
            return try JSONDecoder().decode(LMStudioModelMetadata.self, from: result.data)
        } catch {
            throw LMStudioProviderError.invalidResponse
        }
    }

    private func requestBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) -> [String: Any] {
        [
            "model": endpoint.modelID,
            "temperature": 0,
            "stream": false,
            "max_tokens": contextWindow.reservedResponseTokens,
            "response_format": StructuredTemplateCodec.openAIResponseFormat(for: template),
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
    }

    private func send(_ request: URLRequest) async throws -> TextModelHTTPResponse {
        do {
            return try await client.send(request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut {
                throw LMStudioProviderError.requestTimedOut(
                    TextModelHTTPClient.safeEndpointURL(endpoint.baseURL)
                )
            }
            throw LMStudioProviderError.endpointUnreachable(
                TextModelHTTPClient.safeEndpointURL(endpoint.baseURL)
            )
        }
    }

    private func addAuthorization(to request: inout URLRequest) throws {
        if let secret = try resolvingSecret(endpoint.id) {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
    }

    private func mappedHTTPError(_ statusCode: Int) -> LMStudioProviderError {
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
        OllamaProvider.nativeRoot(url)
    }

    private static func isStructuredOutputUnsupported(_ data: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(
            LMStudioErrorResponse.self,
            from: data
        ) else { return false }
        let message = response.error.message.lowercased()
        return message.contains("response_format")
            || message.contains("json_schema")
            || message.contains("structured output")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct LMStudioChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct LMStudioModelList: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

private struct LMStudioModelMetadata: Decodable {
    let state: String?
    let maxContextLength: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case maxContextLength = "max_context_length"
    }
}

private struct LMStudioErrorResponse: Decodable {
    let error: ErrorValue

    struct ErrorValue: Decodable {
        let message: String
    }
}
