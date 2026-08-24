import Foundation
import StenoDomain

public enum AnthropicMessagesProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case authenticationRejected
    case modelNotFound(String)
    case requestRejected(statusCode: Int)
    case refused
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "Anthropic unter \(url.absoluteString) ist nicht erreichbar."
        case .requestTimedOut(let url):
            "Anthropic unter \(url.absoluteString) hat nicht rechtzeitig geantwortet."
        case .authenticationRejected:
            "Der Anthropic-API-Schlüssel wurde abgelehnt."
        case .modelNotFound(let modelID):
            "Das Modell „\(modelID)“ ist bei Anthropic nicht verfügbar."
        case .requestRejected(let statusCode):
            "Anthropic hat die Anfrage mit HTTP \(statusCode) abgelehnt."
        case .refused:
            "Anthropic hat die angeforderte Ausgabe abgelehnt."
        case .invalidResponse:
            "Anthropic hat keine gültige strukturierte Antwort geliefert."
        }
    }
}

extension AnthropicMessagesProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        let finishReason: String?
        switch self {
        case .endpointUnreachable: (status, code, finishReason) =
            (nil, "endpoint_unreachable", nil)
        case .requestTimedOut: (status, code, finishReason) =
            (nil, "request_timed_out", nil)
        case .authenticationRejected: (status, code, finishReason) =
            (nil, "authentication_rejected", nil)
        case .modelNotFound: (status, code, finishReason) =
            (404, "model_not_found", nil)
        case .requestRejected(let statusCode): (status, code, finishReason) =
            (statusCode, "request_rejected", nil)
        case .refused: (status, code, finishReason) =
            (nil, "refused", "refusal")
        case .invalidResponse: (status, code, finishReason) =
            (nil, "invalid_response", nil)
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.anthropic.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            finishReason: finishReason,
            parsingFailure: code == "invalid_response" ? "structured_response" : nil
        )
    }
}

public struct AnthropicMessagesProvider: StructuredTextModelProvider {
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
        client = TextModelHTTPClient(sessionConfiguration: sessionConfiguration)
        descriptor = EngineDescriptor(
            name: endpoint.name,
            version: "anthropic-messages",
            modelVersion: endpoint.modelID
        )
    }

    public var contextWindow: TextModelContextWindow {
        TextModelContextWindow(
            maximumTokens: endpoint.contextWindowTokens,
            reservedResponseTokens: min(8_192, max(2_048, endpoint.contextWindowTokens / 8)),
            safetyTokens: 256
        )
    }

    public func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        let body = messageBody(
            template: template,
            request: request,
            context: context,
            includesMaximum: false
        )
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return max(1, (data.count + 2) / 3)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let countBody = messageBody(
            template: template,
            request: request,
            context: context,
            includesMaximum: false
        )
        let countResponse = try await send(path: "messages/count_tokens", body: countBody)
        guard (200..<300).contains(countResponse.response.statusCode) else {
            throw mappedHTTPError(countResponse.response.statusCode)
        }
        guard let count = try JSONSerialization.jsonObject(
            with: countResponse.data
        ) as? [String: Any],
              let inputTokens = count["input_tokens"] as? Int
        else {
            throw AnthropicMessagesProviderError.invalidResponse
        }
        let maximumInputTokens = contextWindow.maximumTokens
            - contextWindow.reservedResponseTokens
            - contextWindow.safetyTokens
        guard inputTokens <= maximumInputTokens else {
            throw TextModelProviderError.contextWindowExceeded
        }

        let response = try await send(
            path: "messages",
            body: messageBody(
                template: template,
                request: request,
                context: context,
                includesMaximum: true
            )
        )
        guard (200..<300).contains(response.response.statusCode) else {
            throw mappedHTTPError(response.response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let stopReason = root["stop_reason"] as? String,
              let content = root["content"] as? [[String: Any]]
        else {
            throw AnthropicMessagesProviderError.invalidResponse
        }
        if stopReason == "max_tokens" {
            throw TextModelProviderError.responseTruncated
        }
        if stopReason == "refusal" {
            throw AnthropicMessagesProviderError.refused
        }
        guard stopReason == "end_turn" || stopReason == "stop_sequence" else {
            throw AnthropicMessagesProviderError.invalidResponse
        }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        guard !text.isEmpty else {
            throw AnthropicMessagesProviderError.invalidResponse
        }
        do {
            return try StructuredTemplateCodec.decode(Data(text.utf8), template: template)
        } catch {
            throw AnthropicMessagesProviderError.invalidResponse
        }
    }

    private func messageBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesMaximum: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.modelID,
            "temperature": 0,
            "system": StructuredTemplatePrompt.instructions(for: template, context: context),
            "messages": [[
                "role": "user",
                "content": StructuredTemplatePrompt.prompt(
                    for: request,
                    template: template,
                    context: context
                ),
            ]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": StructuredTemplateCodec.schema(for: template),
                ],
            ],
        ]
        if includesMaximum {
            body["max_tokens"] = contextWindow.reservedResponseTokens
        }
        return body
    }

    private func send(path: String, body: [String: Any]) async throws
        -> TextModelHTTPResponse
    {
        let url = endpoint.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let secret = try resolvingSecret(endpoint.id), !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await client.send(request)
        } catch {
            if error is CancellationError { throw error }
            if (error as? URLError)?.code == .timedOut {
                throw AnthropicMessagesProviderError.requestTimedOut(endpoint.baseURL)
            }
            throw AnthropicMessagesProviderError.endpointUnreachable(endpoint.baseURL)
        }
    }

    private func mappedHTTPError(_ statusCode: Int) -> AnthropicMessagesProviderError {
        switch statusCode {
        case 401, 403: .authenticationRejected
        case 404: .modelNotFound(endpoint.modelID)
        default: .requestRejected(statusCode: statusCode)
        }
    }
}
