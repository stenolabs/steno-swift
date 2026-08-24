import Foundation
import StenoDomain

public enum AmazonBedrockProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case authenticationRejected
    case modelNotFound(String)
    case throttled
    case serviceUnavailable(statusCode: Int)
    case requestRejected(statusCode: Int)
    case refused
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "Amazon Bedrock unter \(url.absoluteString) ist nicht erreichbar."
        case .requestTimedOut(let url):
            "Amazon Bedrock unter \(url.absoluteString) hat nicht rechtzeitig geantwortet."
        case .authenticationRejected:
            "Der Amazon-Bedrock-API-Schlüssel wurde abgelehnt."
        case .modelNotFound(let modelID):
            "Das Modell oder Inferenzprofil „\(modelID)“ ist in Amazon Bedrock nicht verfügbar."
        case .throttled:
            "Amazon Bedrock hat die Anfrage wegen einer Ratenbegrenzung abgelehnt."
        case .serviceUnavailable(let statusCode):
            "Amazon Bedrock ist vorübergehend nicht verfügbar (HTTP \(statusCode))."
        case .requestRejected(let statusCode):
            "Amazon Bedrock hat die Anfrage mit HTTP \(statusCode) abgelehnt."
        case .refused:
            "Amazon Bedrock hat die angeforderte Ausgabe abgelehnt."
        case .invalidResponse:
            "Amazon Bedrock hat keine gültige strukturierte Antwort geliefert."
        }
    }
}

extension AmazonBedrockProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        switch self {
        case .endpointUnreachable: (status, code) = (nil, "endpoint_unreachable")
        case .requestTimedOut: (status, code) = (nil, "request_timed_out")
        case .authenticationRejected: (status, code) = (nil, "authentication_rejected")
        case .modelNotFound: (status, code) = (404, "model_not_found")
        case .throttled: (status, code) = (429, "throttled")
        case .serviceUnavailable(let statusCode):
            (status, code) = (statusCode, "service_unavailable")
        case .requestRejected(let statusCode):
            (status, code) = (statusCode, "request_rejected")
        case .refused: (status, code) = (nil, "refused")
        case .invalidResponse: (status, code) = (nil, "invalid_response")
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.amazonBedrock.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            finishReason: code == "refused" ? "refusal" : nil,
            parsingFailure: code == "invalid_response" ? "structured_response" : nil
        )
    }
}

public struct AmazonBedrockProvider: StructuredTextModelProvider {
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
            version: "bedrock-converse",
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
        let data = try JSONSerialization.data(
            withJSONObject: try requestBody(
                template: template,
                request: request,
                context: context
            ),
            options: [.sortedKeys]
        )
        return max(1, (data.count + 2) / 3)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let model = try AmazonBedrockEndpointPolicy.modelReference(for: endpoint)
        let result = try await send(
            model: model,
            body: requestBody(template: template, request: request, context: context)
        )
        guard (200..<300).contains(result.response.statusCode) else {
            throw mappedHTTPError(result.response.statusCode, model: model)
        }
        guard let root = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let stopReason = root["stopReason"] as? String
        else {
            throw AmazonBedrockProviderError.invalidResponse
        }
        if stopReason == "model_context_window_exceeded" {
            throw TextModelProviderError.contextWindowExceeded
        }
        if ["max_tokens", "maxTokens"].contains(stopReason) {
            throw TextModelProviderError.responseTruncated
        }
        if ["guardrail_intervened", "content_filtered"].contains(stopReason)
            || stopReason.lowercased().contains("refus")
        {
            throw AmazonBedrockProviderError.refused
        }
        guard ["end_turn", "stop_sequence"].contains(stopReason),
              let output = root["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else {
            throw AmazonBedrockProviderError.invalidResponse
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw AmazonBedrockProviderError.invalidResponse
        }
        do {
            return try StructuredTemplateCodec.decode(Data(text.utf8), template: template)
        } catch {
            throw AmazonBedrockProviderError.invalidResponse
        }
    }

    private func requestBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) throws -> [String: Any] {
        let schemaData = try JSONSerialization.data(
            withJSONObject: StructuredTemplateCodec.schema(for: template),
            options: [.sortedKeys]
        )
        return [
            "system": [[
                "text": StructuredTemplatePrompt.instructions(for: template, context: context),
            ]],
            "messages": [[
                "role": "user",
                "content": [[
                    "text": StructuredTemplatePrompt.prompt(
                        for: request,
                        template: template,
                        context: context
                    ),
                ]],
            ]],
            "inferenceConfig": [
                "maxTokens": contextWindow.reservedResponseTokens,
                "temperature": 0,
            ],
            "outputConfig": [
                "textFormat": [
                    "type": "json_schema",
                    "structure": [
                        "jsonSchema": [
                            "name": "template_sections",
                            "description": "Requested meeting report sections",
                            "schema": String(decoding: schemaData, as: UTF8.self),
                        ],
                    ],
                ],
            ],
        ]
    }

    private func send(model: String, body: [String: Any]) async throws
        -> TextModelHTTPResponse
    {
        let url = try converseURL(model: model)
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
                throw AmazonBedrockProviderError.requestTimedOut(endpoint.baseURL)
            }
            throw AmazonBedrockProviderError.endpointUnreachable(endpoint.baseURL)
        }
    }

    private func converseURL(model: String) throws -> URL {
        guard var components = URLComponents(
            url: endpoint.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        components.percentEncodedPath = "/model/\(encoded)/converse"
        guard let url = components.url else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        return url
    }

    private func mappedHTTPError(
        _ statusCode: Int,
        model: String
    ) -> AmazonBedrockProviderError {
        switch statusCode {
        case 401, 403: .authenticationRejected
        case 404: .modelNotFound(model)
        case 429: .throttled
        case 500, 502, 503, 504: .serviceUnavailable(statusCode: statusCode)
        default: .requestRejected(statusCode: statusCode)
        }
    }
}
