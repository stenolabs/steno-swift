import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("External text model provider factory", .serialized)
struct ExternalTextModelProviderFactoryTests {
    @Test("makeProvider builds an OpenAI-compatible provider for the configurable dialect")
    func makeProviderBuildsOpenAICompatibleProvider() throws {
        let endpoint = makeTextModelEndpoint(
            name: "Lokales Gemma",
            baseURL: URL(string: "https://factory-\(UUID().uuidString.lowercased()).example/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: false
        )

        let provider = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)

        #expect(provider.descriptor == EngineDescriptor(
            name: "Lokales Gemma",
            version: "openai-compat",
            modelVersion: "gemma-3"
        ))
    }

    @Test(
        "makeProvider builds a native provider for each local dialect",
        arguments: [
            (TextModelAPIDialect.ollama, "ollama-native"),
            (.lmStudio, "lmstudio-openai-chat"),
        ]
    )
    func makeProviderBuildsNativeLocalProviders(
        dialect: TextModelAPIDialect,
        expectedVersion: String
    ) throws {
        let endpoint = makeTextModelEndpoint(
            name: "Lokal",
            baseURL: URL(string: "http://factory-\(UUID().uuidString.lowercased()).local:11434")!,
            modelID: "model",
            requiresAPIKey: false,
            dialect: dialect
        )

        let provider = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)

        #expect(provider.descriptor == EngineDescriptor(
            name: "Lokal",
            version: expectedVersion,
            modelVersion: "model"
        ))
    }

    @Test(
        "makeProvider builds a native provider for each official cloud dialect",
        arguments: [
            (TextModelAPIDialect.openAI, "openai-responses"),
            (.anthropic, "anthropic-messages"),
        ]
    )
    func makeProviderBuildsNativeCloudProviders(
        dialect: TextModelAPIDialect,
        expectedVersion: String
    ) throws {
        let endpoint = makeTextModelEndpoint(
            name: "Cloud",
            baseURL: URL(string: "https://factory-\(UUID().uuidString.lowercased()).example/v1")!,
            modelID: "model",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: dialect
        )

        let provider = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)

        #expect(provider.descriptor == EngineDescriptor(
            name: "Cloud",
            version: expectedVersion,
            modelVersion: "model"
        ))
    }

    @Test("makeProvider builds the Bedrock Converse provider given a matching configuration")
    func makeProviderBuildsBedrockProvider() throws {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!,
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            bedrock: AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
        )

        let provider = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)

        #expect(provider.descriptor == EngineDescriptor(
            name: "Bedrock",
            version: "bedrock-converse",
            modelVersion: "anthropic.claude-3"
        ))
    }

    @Test("makeProvider rejects a Bedrock dialect without a Bedrock configuration")
    func makeProviderRejectsBedrockWithoutConfiguration() {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!,
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            _ = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)
        }
    }

    @Test("makeProvider surfaces policy validation failures")
    func makeProviderSurfacesPolicyFailures() {
        let endpoint = makeTextModelEndpoint(
            name: "Ungueltig",
            baseURL: URL(string: "http://models.example.com/v1")!,
            modelID: "model",
            requiresAPIKey: false
        )

        #expect(throws: TextModelEndpointPolicyError.insecureRemoteURL) {
            _ = try ExternalTextModelProviderFactory.makeProvider(for: endpoint)
        }
    }

    @Test("probe rejects an unconfigurable Bedrock endpoint before any network call")
    func probeRejectsBedrockWithoutConfigurationBeforeNetwork() async {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .cloud,
            dialect: .amazonBedrock
        )

        await #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            _ = try await ExternalTextModelProviderFactory.probe(endpoint: endpoint)
        }
    }

    @Test("probe checks the model list first, then sends only the synthetic sentence")
    func probeSendsOnlyTheSyntheticSentence() async throws {
        let host = "factory-probe-\(UUID().uuidString.lowercased()).example"
        let endpoint = makeTextModelEndpoint(
            name: "Lokales Gemma",
            baseURL: URL(string: "https://\(host)/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: false
        )
        let recorder = FactoryRequestRecorder()
        FactoryStubURLProtocol.registry.register(host: host) { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("/models") == true {
                return try factoryModelsResponse(modelIDs: ["gemma-3"])
            }
            return try factoryCompletionResponse(
                content: try factoryValidStructuredContent(markdown: "Verbindung steht")
            )
        }
        defer { FactoryStubURLProtocol.registry.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FactoryStubURLProtocol.self]

        let result = try await ExternalTextModelProviderFactory.probe(
            endpoint: endpoint,
            sessionConfiguration: configuration
        )

        #expect(result.isReachable)
        #expect(result.isModelAvailable)
        #expect(result.supportsStructuredGeneration)
        #expect(result.configuredContextWindowTokens == endpoint.contextWindowTokens)
        #expect(result.durationMilliseconds != nil)

        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[0].url?.path.hasSuffix("/models") == true)
        let completionRequest = try #require(recorder.requests.last)
        let body = try factoryRequestJSON(completionRequest)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userMessage = try #require(messages.last?["content"] as? String)
        #expect(userMessage.contains("Synthetic connection test"))
        // Es verlaesst kein Meeting-Inhalt das Geraet: der synthetische Satz
        // ist der einzige Inhalt, ein echtes Transkript wird nie gesendet.
        #expect(!userMessage.contains("VERTRAULICH"))
    }

    @Test("probe does not attempt a structured generation when the model is missing")
    func probeSkipsGenerationWhenModelIsMissing() async throws {
        let host = "factory-probe-missing-\(UUID().uuidString.lowercased()).example"
        let endpoint = makeTextModelEndpoint(
            name: "Lokales Gemma",
            baseURL: URL(string: "https://\(host)/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: false
        )
        let recorder = FactoryRequestRecorder()
        FactoryStubURLProtocol.registry.register(host: host) { request in
            recorder.append(request)
            return try factoryModelsResponse(modelIDs: ["other-model"])
        }
        defer { FactoryStubURLProtocol.registry.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FactoryStubURLProtocol.self]

        let result = try await ExternalTextModelProviderFactory.probe(
            endpoint: endpoint,
            sessionConfiguration: configuration
        )

        #expect(result.isReachable)
        #expect(!result.isModelAvailable)
        #expect(!result.supportsStructuredGeneration)
        #expect(recorder.requests.count == 1)
    }
}

private final class FactoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    @discardableResult
    func append(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedRequests.append(request)
        return storedRequests.count
    }
}

private func factoryValidStructuredContent(markdown: String) throws -> String {
    let sections: [String: String] = [
        "summary": markdown,
        "key-topics": "",
        "decisions": "",
        "action-items": "",
    ]
    let data = try JSONSerialization.data(withJSONObject: ["sections": sections])
    return String(decoding: data, as: UTF8.self)
}

private func factoryModelsResponse(modelIDs: [String]) throws -> FactoryStubResponse {
    let body: [String: Any] = [
        "object": "list",
        "data": modelIDs.map { modelID in
            [
                "id": modelID,
                "object": "model",
                "created": 1_700_000_000,
                "owned_by": "local",
            ] as [String: Any]
        },
    ]
    return FactoryStubResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        data: try JSONSerialization.data(withJSONObject: body)
    )
}

private func factoryCompletionResponse(content: String) throws -> FactoryStubResponse {
    let body: [String: Any] = [
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "created": 1_700_000_000,
        "model": "gemma-3",
        "choices": [[
            "index": 0,
            "message": [
                "role": "assistant",
                "content": content,
            ],
            "finish_reason": "stop",
        ]],
        "usage": [
            "prompt_tokens": 10,
            "completion_tokens": 20,
            "total_tokens": 30,
        ],
    ]
    return FactoryStubResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        data: try JSONSerialization.data(withJSONObject: body)
    )
}

private func factoryRequestJSON(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 {
                break
            }
            collected.append(buffer, count: count)
        }
        data = collected
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct FactoryStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

private final class FactoryStubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: FactoryStubURLProtocol.Handler] = [:]

    func register(host: String, handler: @escaping FactoryStubURLProtocol.Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    func handler(host: String) -> FactoryStubURLProtocol.Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private final class FactoryStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> FactoryStubResponse

    static let registry = FactoryStubRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map { registry.handler(host: $0) != nil } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host(),
              let handler = Self.registry.handler(host: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
