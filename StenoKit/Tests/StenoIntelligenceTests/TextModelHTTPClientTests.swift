import Foundation
@testable import StenoIntelligence
import Testing

@Suite("Text model HTTP client", .serialized)
struct TextModelHTTPClientTests {
    @Test("the client-owned session rejects every HTTP redirect")
    func clientOwnedSessionRejectsEveryHTTPRedirect() throws {
        let client = TextModelHTTPClient(sessionConfiguration: .ephemeral)
        let session = client.sessionOwner.session
        let delegate = try #require(
            session.delegate as? RedirectBlockingURLSessionDelegate
        )
        let sourceURL = URL(string: "https://chosen-endpoint.example/v1/models")!
        let destinationURL = URL(string: "https://other-endpoint.example/v1/models")!
        let task = session.dataTask(with: sourceURL)
        let response = HTTPURLResponse(
            url: sourceURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": destinationURL.absoluteString]
        )!
        let decision = RedirectDecisionRecorder()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destinationURL)
        ) { request in
            decision.record(request)
        }

        #expect(decision.result.wasCalled)
        #expect(decision.result.request == nil)
    }

    @Test("a 307 with a Location header is not followed and triggers no second request")
    func redirectIsNeverFollowedToASecondHost() async {
        let sourceHost = "client-redirect-source-\(UUID().uuidString.lowercased()).example"
        let destinationHost = "client-redirect-target-\(UUID().uuidString.lowercased()).example"
        let destinationURL = URL(string: "https://\(destinationHost)/v1/chat/completions")!
        let sourceRecorder = HostRequestRecorder()
        let destinationRecorder = HostRequestRecorder()
        MultiHostStubURLProtocol.registry.register(host: sourceHost) { request in
            sourceRecorder.append(request)
            return MultiHostStubResponse(
                statusCode: 307,
                headers: ["Location": destinationURL.absoluteString],
                data: Data()
            )
        }
        MultiHostStubURLProtocol.registry.register(host: destinationHost) { request in
            destinationRecorder.append(request)
            return MultiHostStubResponse(statusCode: 200, headers: [:], data: Data("{}".utf8))
        }
        defer {
            MultiHostStubURLProtocol.registry.remove(host: sourceHost)
            MultiHostStubURLProtocol.registry.remove(host: destinationHost)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultiHostStubURLProtocol.self]
        let client = TextModelHTTPClient(sessionConfiguration: configuration)

        await #expect(throws: TextModelHTTPClientError.redirectBlocked) {
            _ = try await client.send(URLRequest(
                url: URL(string: "https://\(sourceHost)/v1/chat/completions")!
            ))
        }

        #expect(sourceRecorder.count == 1)
        #expect(destinationRecorder.count == 0)
    }

    @Test("429 retries are bounded and Retry-After is capped")
    func retryAfterIsCapped() async throws {
        let state = HTTPStubState(responses: [429, 429, 200])
        let configuration = makeHTTPSessionConfiguration(state: state)
        let sleeps = SleepRecorder()
        let client = TextModelHTTPClient(
            sessionConfiguration: configuration,
            sleeper: { duration in await sleeps.record(duration) }
        )

        let result = try await client.send(URLRequest(
            url: URL(string: "https://provider.example/test")!
        ))

        #expect(result.response.statusCode == 200)
        #expect(await state.requestCount == 3)
        #expect(await sleeps.values == [.seconds(60), .seconds(60)])
    }

    @Test("authentication failures are not retried")
    func authFailureDoesNotRetry() async throws {
        let state = HTTPStubState(responses: [401, 200])
        let configuration = makeHTTPSessionConfiguration(state: state)
        let client = TextModelHTTPClient(sessionConfiguration: configuration)

        let result = try await client.send(URLRequest(
            url: URL(string: "https://provider.example/test")!
        ))

        #expect(result.response.statusCode == 401)
        #expect(await state.requestCount == 1)
    }

    @Test("409 retries only when the server marks it as temporary")
    func conflictRequiresRetryAfter() async throws {
        let temporary = HTTPStubState(
            responses: [409, 200],
            retryAfterStatuses: [409]
        )
        let temporaryClient = TextModelHTTPClient(
            sessionConfiguration: makeHTTPSessionConfiguration(state: temporary),
            sleeper: { _ in }
        )

        let retried = try await temporaryClient.send(URLRequest(
            url: URL(string: "https://provider.example/test")!
        ))
        #expect(retried.response.statusCode == 200)
        #expect(await temporary.requestCount == 2)

        let terminal = HTTPStubState(responses: [409, 200])
        let terminalClient = TextModelHTTPClient(
            sessionConfiguration: makeHTTPSessionConfiguration(state: terminal)
        )

        let notRetried = try await terminalClient.send(URLRequest(
            url: URL(string: "https://provider.example/test")!
        ))
        #expect(notRetried.response.statusCode == 409)
        #expect(await terminal.requestCount == 1)
    }

    @Test("cancellation during backoff prevents another request")
    func cancellationStopsRetry() async throws {
        let state = HTTPStubState(responses: [429, 200])
        let client = TextModelHTTPClient(
            sessionConfiguration: makeHTTPSessionConfiguration(state: state),
            sleeper: { _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            try await client.send(URLRequest(
                url: URL(string: "https://provider.example/test")!
            ))
        }
        #expect(await state.requestCount == 1)
    }

    @Test("safe endpoint URL removes credentials query and fragment")
    func endpointURLIsSanitized() throws {
        let unsafe = try #require(URL(
            string: "https://user:secret@provider.example/v1?token=secret#private"
        ))

        #expect(
            TextModelHTTPClient.safeEndpointURL(unsafe).absoluteString
                == "https://provider.example/v1"
        )
    }
}

private func makeHTTPSessionConfiguration(state: HTTPStubState) -> URLSessionConfiguration {
    HTTPClientStubURLProtocol.state = state
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPClientStubURLProtocol.self]
    return configuration
}

private actor HTTPStubState {
    private var responses: [Int]
    private let retryAfterStatuses: Set<Int>
    private(set) var requestCount = 0

    init(responses: [Int], retryAfterStatuses: Set<Int> = [429]) {
        self.responses = responses
        self.retryAfterStatuses = retryAfterStatuses
    }

    func next() -> (status: Int, hasRetryAfter: Bool) {
        requestCount += 1
        let status = responses.isEmpty ? 500 : responses.removeFirst()
        return (status, retryAfterStatuses.contains(status))
    }
}

private actor SleepRecorder {
    private(set) var values: [Duration] = []

    func record(_ duration: Duration) {
        values.append(duration)
    }
}

private final class HTTPClientStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state: HTTPStubState?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task {
            guard let state = Self.state else { return }
            let next = await state.next()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: next.status,
                httpVersion: "HTTP/1.1",
                headerFields: next.hasRetryAfter ? ["Retry-After": "120"] : nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private struct MultiHostStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

private final class MultiHostStubRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> MultiHostStubResponse

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    func handler(host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private final class MultiHostStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MultiHostStubRegistry()

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
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HostRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedCount += 1
    }
}

private final class RedirectDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var wasCalled = false
    private var request: URLRequest?

    var result: (wasCalled: Bool, request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        return (wasCalled, request)
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        wasCalled = true
        self.request = request
        lock.unlock()
    }
}
