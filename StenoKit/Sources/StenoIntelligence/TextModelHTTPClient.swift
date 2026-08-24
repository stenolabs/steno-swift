import Foundation

/// Antwort eines abgeschlossenen, nicht umgeleiteten Requests.
struct TextModelHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

enum TextModelHTTPClientError: Error, Equatable, Sendable {
    /// Der Endpunkt hat mit einem 3xx-Status geantwortet. Die eigene Session
    /// folgt keiner Umleitung (siehe RedirectBlockingURLSessionDelegate);
    /// dieser Fehler ist die zweite, unabhaengige Verriegelung, damit auch
    /// ein Aufrufer, der Statuscodes nicht sorgfaeltig prueft, keinem
    /// Redirect folgen kann.
    case redirectBlocked
}

/// Beantwortet jede Umleitung mit `nil`, also "nicht folgen". Damit liefert
/// URLSession die 3xx-Antwort selbst aus, statt dem Location-Header zu einem
/// fremden Host zu folgen.
final class RedirectBlockingURLSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Haelt die einzige URLSession dieses Transports und ihren
/// Redirect-blockierenden Delegate zusammen; deren Lebensdauer haengt am
/// Client, nicht an einer von aussen hereingereichten Session.
final class URLSessionOwner: @unchecked Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(
            configuration: configuration,
            delegate: RedirectBlockingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }
}

/// Der einzige Ort, an dem StenoIntelligence eine URLSession konstruiert.
/// Jeder externe Textmodell-Provider sendet ueber diesen Client statt eine
/// eigene Session zu bauen, und erbt damit zwangslaeufig die
/// Umleitungssperre. `TextModelTransportInventoryTests` erzwingt das fuer
/// jede Datei unter Sources/StenoIntelligence.
struct TextModelHTTPClient: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let sessionOwner: URLSessionOwner
    private let maximumRetries: Int
    private let sleeper: Sleeper

    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        maximumRetries: Int = 2,
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.sessionOwner = URLSessionOwner(configuration: sessionConfiguration)
        self.maximumRetries = maximumRetries
        self.sleeper = sleeper
    }

    func send(_ request: URLRequest) async throws -> TextModelHTTPResponse {
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await sessionOwner.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                // 3xx ist immer terminal, nie ein Retry-Kandidat: eine
                // blockierte Umleitung wird durch erneutes Senden nicht
                // erfolgreich.
                guard !(300..<400).contains(http.statusCode) else {
                    throw TextModelHTTPClientError.redirectBlocked
                }
                guard retryCount < maximumRetries,
                      let delay = retryDelay(for: http, retryCount: retryCount)
                else {
                    return TextModelHTTPResponse(data: data, response: http)
                }
                retryCount += 1
                try await sleeper(delay)
            } catch let error as TextModelHTTPClientError {
                throw error
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                guard retryCount < maximumRetries,
                      shouldRetryTransport(error)
                else {
                    throw error
                }
                let delay = Duration.seconds(1 << retryCount)
                retryCount += 1
                try await sleeper(delay)
            }
        }
    }

    static func safeEndpointURL(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return url }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func retryDelay(
        for response: HTTPURLResponse,
        retryCount: Int
    ) -> Duration? {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        if response.statusCode == 409, retryAfter == nil {
            return nil
        }
        guard [408, 409, 429, 500, 502, 503, 504].contains(response.statusCode) else {
            return nil
        }
        if let value = retryAfter,
           let seconds = Double(value)
        {
            return .seconds(min(60, max(0, seconds)))
        }
        return .seconds(1 << retryCount)
    }

    private func shouldRetryTransport(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return ![
            .badURL,
            .unsupportedURL,
            .userAuthenticationRequired,
            .cancelled,
        ].contains(urlError.code)
    }
}
