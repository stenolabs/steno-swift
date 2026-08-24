import Foundation
import StenoDomain

public enum OpenAIResponsesProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case authenticationRejected
    case modelNotFound(String)
    case requestRejected(statusCode: Int)
    case refused
    case reasoningBudgetExceeded
    case incomplete(String?)
    case failed(String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "OpenAI unter \(url.absoluteString) ist nicht erreichbar."
        case .requestTimedOut(let url):
            "OpenAI unter \(url.absoluteString) hat nicht rechtzeitig geantwortet."
        case .authenticationRejected:
            "Der OpenAI-API-Schlüssel wurde abgelehnt."
        case .modelNotFound(let modelID):
            "Das Modell „\(modelID)“ ist bei OpenAI nicht verfügbar."
        case .requestRejected(let statusCode):
            "OpenAI hat die Anfrage mit HTTP \(statusCode) abgelehnt."
        case .refused:
            "OpenAI hat die angeforderte Ausgabe abgelehnt."
        case .reasoningBudgetExceeded:
            "OpenAI hat das Reasoning-Budget ausgeschöpft, bevor die Antwort beginnen konnte."
        case .incomplete:
            "OpenAI hat die Antwort nicht vollständig erzeugt."
        case .failed:
            "OpenAI konnte die Antwort nicht erzeugen."
        case .invalidResponse:
            "OpenAI hat keine gültige strukturierte Antwort geliefert."
        }
    }
}

extension OpenAIResponsesProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        let finishReason: String?
        let parsingFailure: String?
        switch self {
        case .endpointUnreachable:
            (status, code, finishReason, parsingFailure) =
                (nil, "endpoint_unreachable", nil, nil)
        case .requestTimedOut:
            (status, code, finishReason, parsingFailure) =
                (nil, "request_timed_out", nil, nil)
        case .authenticationRejected:
            (status, code, finishReason, parsingFailure) =
                (nil, "authentication_rejected", nil, nil)
        case .modelNotFound:
            (status, code, finishReason, parsingFailure) =
                (404, "model_not_found", nil, nil)
        case .requestRejected(let statusCode):
            (status, code, finishReason, parsingFailure) =
                (statusCode, "request_rejected", nil, nil)
        case .refused:
            (status, code, finishReason, parsingFailure) =
                (nil, "refused", "refusal", nil)
        case .reasoningBudgetExceeded:
            (status, code, finishReason, parsingFailure) =
                (nil, "reasoning_budget_exceeded", "max_output_tokens", nil)
        case .incomplete(let reason):
            (status, code, finishReason, parsingFailure) =
                (nil, "incomplete", reason, nil)
        case .failed(let reason):
            (status, code, finishReason, parsingFailure) =
                (nil, "failed", reason, nil)
        case .invalidResponse:
            (status, code, finishReason, parsingFailure) =
                (nil, "invalid_response", nil, "structured_response")
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.openAI.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            finishReason: finishReason,
            parsingFailure: parsingFailure
        )
    }
}

public struct OpenAIResponsesProvider: StructuredTextModelProvider {
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
            version: "openai-responses",
            modelVersion: endpoint.modelID
        )
    }

    public var contextWindow: TextModelContextWindow {
        TextModelContextWindow(
            maximumTokens: endpoint.contextWindowTokens,
            reservedResponseTokens: min(
                endpoint.contextWindowTokens,
                visibleOutputBudget * 3
            ),
            safetyTokens: 256
        )
    }

    private var visibleOutputBudget: Int {
        min(8_192, max(512, endpoint.contextWindowTokens / 8))
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
            maximumOutputTokens: initialOutputBudget
        )
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return max(1, (data.count + 2) / 3)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let estimatedInputTokens = try await inputTokenCount(
            template: template,
            request: request,
            context: context
        )
        let maximumInputTokens = contextWindow.maximumTokens
            - contextWindow.reservedResponseTokens
            - contextWindow.safetyTokens
        guard estimatedInputTokens <= maximumInputTokens else {
            throw TextModelProviderError.contextWindowExceeded
        }
        let maximumBudget = endpoint.contextWindowTokens
            - estimatedInputTokens
            - contextWindow.safetyTokens
        var outputBudget = min(initialOutputBudget, maximumBudget)
        var root: [String: Any]?

        for attempt in 0...1 {
            let result = try await send(
                path: "responses",
                body: requestBody(
                    template: template,
                    request: request,
                    context: context,
                    maximumOutputTokens: outputBudget
                )
            )
            guard (200..<300).contains(result.response.statusCode) else {
                throw mappedHTTPError(result.response.statusCode)
            }
            guard let responseRoot = try JSONSerialization.jsonObject(
                with: result.data
            ) as? [String: Any], let status = responseRoot["status"] as? String else {
                throw OpenAIResponsesProviderError.invalidResponse
            }
            switch status {
            case "completed":
                root = responseRoot
            case "incomplete":
                let details = responseRoot["incomplete_details"] as? [String: Any]
                let reason = details?["reason"] as? String
                guard reason == "max_output_tokens" else {
                    throw OpenAIResponsesProviderError.incomplete(reason)
                }
                let usage = responseRoot["usage"] as? [String: Any]
                let outputDetails = usage?["output_tokens_details"] as? [String: Any]
                let reasoningTokens = outputDetails?["reasoning_tokens"] as? Int ?? 0
                guard reasoningTokens > 0 else {
                    throw TextModelProviderError.responseTruncated
                }
                let nextBudget = min(
                    maximumBudget,
                    outputBudget + max(visibleOutputBudget, reasoningTokens)
                )
                guard attempt == 0, nextBudget > outputBudget else {
                    throw OpenAIResponsesProviderError.reasoningBudgetExceeded
                }
                outputBudget = nextBudget
                continue
            case "failed":
                let error = responseRoot["error"] as? [String: Any]
                throw OpenAIResponsesProviderError.failed(error?["code"] as? String)
            default:
                throw OpenAIResponsesProviderError.invalidResponse
            }
            break
        }
        guard let root else {
            throw OpenAIResponsesProviderError.reasoningBudgetExceeded
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw OpenAIResponsesProviderError.invalidResponse
        }
        var texts: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "refusal" {
                    throw OpenAIResponsesProviderError.refused
                }
                if block["type"] as? String == "output_text",
                   let text = block["text"] as? String
                {
                    texts.append(text)
                }
            }
        }
        guard !texts.isEmpty else {
            throw OpenAIResponsesProviderError.invalidResponse
        }
        do {
            return try StructuredTemplateCodec.decode(
                Data(texts.joined().utf8),
                template: template
            )
        } catch {
            throw OpenAIResponsesProviderError.invalidResponse
        }
    }

    private func requestBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        maximumOutputTokens: Int
    ) -> [String: Any] {
        [
            "model": endpoint.modelID,
            "instructions": StructuredTemplatePrompt.instructions(for: template, context: context),
            "input": StructuredTemplatePrompt.prompt(
                for: request,
                template: template,
                context: context
            ),
            "store": false,
            "max_output_tokens": maximumOutputTokens,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "template_sections",
                    "strict": true,
                    "schema": StructuredTemplateCodec.schema(for: template),
                ],
            ],
        ]
    }

    private var initialOutputBudget: Int {
        min(
            endpoint.contextWindowTokens,
            visibleOutputBudget * 2
        )
    }

    private func send(path: String, body: [String: Any]) async throws
        -> TextModelHTTPResponse
    {
        let url = endpoint.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = try resolvingSecret(endpoint.id), !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await client.send(request)
        } catch {
            if error is CancellationError { throw error }
            if (error as? URLError)?.code == .timedOut {
                throw OpenAIResponsesProviderError.requestTimedOut(endpoint.baseURL)
            }
            throw OpenAIResponsesProviderError.endpointUnreachable(endpoint.baseURL)
        }
    }

    private func mappedHTTPError(_ statusCode: Int) -> OpenAIResponsesProviderError {
        switch statusCode {
        case 401, 403: .authenticationRejected
        case 404: .modelNotFound(endpoint.modelID)
        default: .requestRejected(statusCode: statusCode)
        }
    }
}
