import Foundation
import StenoDomain
@testable import StenoIntelligence
import Testing

@Suite("LM Studio provider", .serialized)
struct LMStudioProviderTests {
    @Test("generation uses the strict LM Studio Chat Completions contract")
    func generationUsesLMStudioContract() async throws {
        let recorder = LMStudioRequestRecorder()
        let configuration = makeLMStudioConfiguration { request in
            recorder.append(request)
            return try lmStudioResponse(request, object: [
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": validLMStudioContent("Fertig"),
                    ],
                    "finish_reason": "stop",
                ]],
            ])
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(output.sections.first?.markdown == "Fertig")
        #expect(provider.descriptor.version == "lmstudio-openai-chat")
        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/prefix/v1/chat/completions")
        let body = try lmStudioRequestJSON(request)
        #expect(body["temperature"] as? Int == 0)
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 2_048)
        #expect(body["think"] == nil)
        #expect(body["options"] == nil)
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
    }

    @Test("schema rejection does not fall back to unstructured text")
    func schemaRejectionFailsClosed() async {
        let recorder = LMStudioRequestRecorder()
        let configuration = makeLMStudioConfiguration { request in
            recorder.append(request)
            return try lmStudioResponse(
                request,
                status: 400,
                object: ["error": ["message": "response_format is unsupported"]]
            )
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
            sessionConfiguration: configuration
        )

        await #expect(throws: LMStudioProviderError.structuredOutputUnsupported) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
        #expect(recorder.requests.count == 1)
    }

    @Test("probe preserves prefixes and reports a smaller loaded context")
    func probeReportsSmallerLoadedContext() async throws {
        let recorder = LMStudioRequestRecorder()
        let configuration = makeLMStudioConfiguration { request in
            recorder.append(request)
            switch request.url?.path {
            case "/prefix/v1/models":
                return try lmStudioResponse(request, object: [
                    "data": [["id": "google/gemma-4-e4b"]],
                ])
            case "/prefix/api/v0/models/google/gemma-4-e4b":
                return try lmStudioResponse(request, object: [
                    "id": "google/gemma-4-e4b",
                    "state": "loaded",
                    "max_context_length": 8_192,
                ])
            default:
                Issue.record("Unexpected request \(request.url?.absoluteString ?? "nil")")
                return try lmStudioResponse(request, status: 500, object: [:])
            }
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
            sessionConfiguration: configuration
        )

        let result = try await provider.probe()

        #expect(result.isModelAvailable)
        #expect(!result.supportsStructuredGeneration)
        #expect(result.configuredContextWindowTokens == 16_384)
        #expect(result.reportedContextWindowTokens == 8_192)
        #expect(recorder.requests.count == 2)
    }

    @Test("a larger reported context never expands the configured limit")
    func largerReportedContextDoesNotExpandConfiguration() async throws {
        let configuration = makeLMStudioConfiguration { request in
            switch request.url?.path {
            case "/prefix/v1/models":
                return try lmStudioResponse(request, object: [
                    "data": [["id": "google/gemma-4-e4b"]],
                ])
            case "/prefix/api/v0/models/google/gemma-4-e4b":
                return try lmStudioResponse(request, object: [
                    "id": "google/gemma-4-e4b",
                    "state": "loaded",
                    "max_context_length": 131_072,
                ])
            default:
                return try lmStudioResponse(request, object: [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "content": validLMStudioContent("Synthetic"),
                        ],
                        "finish_reason": "stop",
                    ]],
                ])
            }
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
            sessionConfiguration: configuration
        )

        let result = try await provider.probe()

        #expect(provider.contextWindow.maximumTokens == 16_384)
        #expect(result.reportedContextWindowTokens == 131_072)
        #expect(result.supportsStructuredGeneration)
    }

    @Test("an unloaded model is distinct from an unreachable endpoint")
    func unloadedModelIsExplicit() async {
        let configuration = makeLMStudioConfiguration { request in
            if request.url?.path == "/prefix/v1/models" {
                return try lmStudioResponse(request, object: [
                    "data": [["id": "google/gemma-4-e4b"]],
                ])
            }
            return try lmStudioResponse(request, object: [
                "id": "google/gemma-4-e4b",
                "state": "not-loaded",
                "max_context_length": 131_072,
            ])
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
            sessionConfiguration: configuration
        )

        await #expect(throws: LMStudioProviderError.modelNotLoaded("google/gemma-4-e4b")) {
            _ = try await provider.probe()
        }
    }

    @Test("a server error exposes a content-safe diagnostic")
    func serverErrorExposesDiagnostic() async {
        let configuration = makeLMStudioConfiguration { request in
            try lmStudioResponse(request, status: 503, object: ["error": ["message": "overloaded"]])
        }
        let provider = LMStudioProvider(
            endpoint: lmStudioEndpoint(),
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
            #expect(diagnostic.dialect == TextModelAPIDialect.lmStudio.rawValue)
            #expect(diagnostic.httpStatus == 503)
            #expect(diagnostic.providerCode == "server_error")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private final class LMStudioRequestRecorder: @unchecked Sendable {
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

private func lmStudioEndpoint() -> TextModelEndpoint {
    makeTextModelEndpoint(
        name: "LM Studio",
        baseURL: URL(string: "http://localhost:1234/prefix/v1")!,
        modelID: "google/gemma-4-e4b",
        requiresAPIKey: false,
        hosting: .selfHosted,
        dialect: .lmStudio,
        contextWindowTokens: 16_384
    )
}

private func validLMStudioContent(_ markdown: String) -> String {
    """
    {"sections":{"summary":"\(markdown)","key-topics":"\(markdown)","decisions":"\(markdown)","action-items":"\(markdown)"}}
    """
}

private func makeLMStudioConfiguration(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSessionConfiguration {
    LMStudioURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LMStudioURLProtocol.self]
    return configuration
}

private func lmStudioResponse(
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

private func lmStudioRequestJSON(_ request: URLRequest) throws -> [String: Any] {
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

private final class LMStudioURLProtocol: URLProtocol, @unchecked Sendable {
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
