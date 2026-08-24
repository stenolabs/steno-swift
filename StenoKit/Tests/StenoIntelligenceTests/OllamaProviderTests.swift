import Foundation
import StenoDomain
@testable import StenoIntelligence
import Testing

@Suite("Native Ollama provider", .serialized)
struct OllamaProviderTests {
    @Test("generation uses Ollama native chat options and schema")
    func generationUsesNativeContract() async throws {
        let recorder = OllamaRequestRecorder()
        let configuration = makeOllamaConfiguration { request in
            recorder.append(request)
            return try ollamaResponse(
                request,
                object: [
                    "message": [
                        "role": "assistant",
                        "content": validOllamaContent("Fertig"),
                    ],
                    "done": true,
                    "done_reason": "stop",
                    "eval_count": 42,
                ]
            )
        }
        let provider = OllamaProvider(
            endpoint: ollamaEndpoint(contextTokens: 16_384),
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .map(TranscriptChunk(turns: [])),
            context: RenderContext()
        )

        #expect(output.sections.first?.markdown == "Fertig")
        #expect(provider.descriptor.version == "ollama-native")
        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/api/chat")
        let body = try ollamaRequestJSON(request)
        #expect(body["model"] as? String == "gemma4:12b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["think"] as? Bool == false)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Int == 0)
        #expect(options["num_ctx"] as? Int == 16_384)
        #expect(options["num_predict"] as? Int == 2_048)
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["additionalProperties"] as? Bool == false)
        let properties = try #require(format["properties"] as? [String: Any])
        let sections = try #require(properties["sections"] as? [String: Any])
        #expect(Set(sections["required"] as? [String] ?? []) == [
            "summary", "key-topics", "decisions", "action-items",
        ])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test("probe lists the exact model and reports native structured generation")
    func probeUsesTagsAndSyntheticGeneration() async throws {
        let recorder = OllamaRequestRecorder()
        let configuration = makeOllamaConfiguration { request in
            recorder.append(request)
            if request.url?.path == "/api/tags" {
                return try ollamaResponse(request, object: [
                    "models": [["name": "gemma4:12b", "model": "gemma4:12b"]],
                ])
            }
            return try ollamaResponse(request, object: [
                "message": [
                    "role": "assistant",
                    "content": validOllamaContent("Synthetic"),
                ],
                "done": true,
                "done_reason": "stop",
            ])
        }
        let provider = OllamaProvider(
            endpoint: ollamaEndpoint(),
            sessionConfiguration: configuration
        )

        let result = try await provider.probe()

        #expect(result.isReachable)
        #expect(result.isModelAvailable)
        #expect(result.supportsStructuredGeneration)
        #expect(result.configuredContextWindowTokens == 16_384)
        #expect(recorder.requests.map(\.url?.path) == ["/api/tags", "/api/chat"])
        let generationBody = try ollamaRequestJSON(
            try #require(recorder.requests.last)
        )
        let messages = try #require(generationBody["messages"] as? [[String: Any]])
        let joined = messages.compactMap { $0["content"] as? String }.joined()
        #expect(joined.contains("Synthetic connection test."))
    }

    @Test("think incompatibility retries once without guessing another dialect")
    func unsupportedThinkRetriesOnce() async throws {
        let recorder = OllamaRequestRecorder()
        let configuration = makeOllamaConfiguration { request in
            let call = recorder.append(request)
            if call == 1 {
                return try ollamaResponse(
                    request,
                    status: 400,
                    object: ["error": "unknown field think"]
                )
            }
            return try ollamaResponse(request, object: [
                "message": [
                    "role": "assistant",
                    "content": validOllamaContent("Fallback"),
                ],
                "done": true,
                "done_reason": "stop",
            ])
        }
        let provider = OllamaProvider(
            endpoint: ollamaEndpoint(),
            sessionConfiguration: configuration
        )

        _ = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(recorder.requests.count == 2)
        let first = try ollamaRequestJSON(recorder.requests[0])
        let second = try ollamaRequestJSON(recorder.requests[1])
        #expect(first["think"] as? Bool == false)
        #expect(second["think"] == nil)
    }

    @Test("length completion is classified as truncation")
    func lengthIsTruncation() async {
        let configuration = makeOllamaConfiguration { request in
            try ollamaResponse(request, object: [
                "message": ["role": "assistant", "content": "{}"],
                "done": true,
                "done_reason": "length",
            ])
        }
        let provider = OllamaProvider(
            endpoint: ollamaEndpoint(),
            sessionConfiguration: configuration
        )

        await #expect(throws: TextModelProviderError.responseTruncated) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
    }

    @Test("a server error exposes a content-safe diagnostic")
    func serverErrorExposesDiagnostic() async {
        let configuration = makeOllamaConfiguration { request in
            try ollamaResponse(request, status: 503, object: ["error": "overloaded"])
        }
        let provider = OllamaProvider(
            endpoint: ollamaEndpoint(),
            sessionConfiguration: configuration
        )

        do {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
            Issue.record("Expected the provider failure")
        } catch let error as any TextModelDiagnosticProviding {
            let diagnostic = error.textModelDiagnostic
            #expect(diagnostic.dialect == TextModelAPIDialect.ollama.rawValue)
            #expect(diagnostic.httpStatus == 503)
            #expect(diagnostic.providerCode == "server_error")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private final class OllamaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    @discardableResult
    func append(_ request: URLRequest) -> Int {
        lock.withLock {
            storage.append(request)
            return storage.count
        }
    }
}

private func ollamaEndpoint(contextTokens: Int = 16_384) -> TextModelEndpoint {
    makeTextModelEndpoint(
        name: "Ollama 4070 Ti",
        baseURL: URL(string: "http://192.168.1.10:11434/v1")!,
        modelID: "gemma4:12b",
        requiresAPIKey: false,
        hosting: .selfHosted,
        dialect: .ollama,
        contextWindowTokens: contextTokens
    )
}

private func validOllamaContent(_ markdown: String) -> String {
    """
    {"sections":{"summary":"\(markdown)","key-topics":"\(markdown)","decisions":"\(markdown)","action-items":"\(markdown)"}}
    """
}

private func makeOllamaConfiguration(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSessionConfiguration {
    OllamaURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OllamaURLProtocol.self]
    return configuration
}

private func ollamaResponse(
    _ request: URLRequest,
    status: Int = 200,
    object: Any
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, try JSONSerialization.data(withJSONObject: object))
}

private func ollamaRequestJSON(_ request: URLRequest) throws -> [String: Any] {
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
            if count == 0 { break }
            collected.append(buffer, count: count)
        }
        data = collected
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class OllamaURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
