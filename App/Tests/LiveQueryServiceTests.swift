import Foundation
import StenoIntelligence
import StenoTranscription
import Testing
@testable import steno_macos

/// Thread-safe cancellation probe shared with the hanging stream task.
final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Streams the given chunks, then stays open until cancelled unless
/// `finishes` is set.
struct MockLiveQueryAnswerer: LiveQueryAnswering {
    var chunks: [String] = []
    var finishes = true
    var cancellationCounter: CancellationCounter?

    func stream(
        systemInstructions: String,
        userPrompt: String
    ) -> AsyncThrowingStream<String, any Error> {
        let emittedChunks = chunks
        let shouldFinish = finishes
        let counter = cancellationCounter
        return AsyncThrowingStream { continuation in
            let worker = Task {
                if shouldFinish {
                    for chunk in emittedChunks {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } else {
                    // Hang until the owner cancels the query.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    throw CancellationError()
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    counter?.increment()
                }
                worker.cancel()
            }
        }
    }
}

@MainActor
@Suite("Live query service")
struct LiveQueryServiceTests {
    /// Polls until the service leaves the active state so background chunk
    /// delivery never makes an assertion timing-dependent.
    private func waitForIdle(_ service: LiveQueryService) async {
        for _ in 0..<200 {
            guard !service.isActive else {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            return
        }
    }

    private static func finalizedRow(text: String) -> LiveTranscriptFeed.Row {
        // The feed projects Row only internally; tests build the equivalent
        // through a feed application to stay on the public surface.
        var feed = LiveTranscriptFeed()
        feed.apply(
            .final(.init(
                localeIdentifier: "",
                blocks: [.init(
                    channel: .microphone,
                    text: text,
                    start: 0,
                    end: 1,
                    words: []
                )]
            )),
            for: .microphone
        )
        return feed.rows[0]
    }

    private func makeService(
        answerer: @escaping @MainActor () throws -> any LiveQueryAnswering,
        rows: [LiveTranscriptFeed.Row]
    ) -> LiveQueryService {
        LiveQueryService(
            makeAnswerer: answerer,
            contextProvider: {
                LiveQueryContext(rows: rows, meetingTitle: "Test", participantNames: [])
            }
        )
    }

    @Test("a new question cancels the previous in-flight query")
    func newQueryCancelsPrevious() async throws {
        let cancellations = CancellationCounter()
        let hanging = MockLiveQueryAnswerer(
            chunks: [],
            finishes: false,
            cancellationCounter: cancellations
        )
        let service = makeService(answerer: { hanging },
                                  rows: [Self.finalizedRow(text: "Material.")])

        service.ask(question: "First question?")
        #expect(service.isActive)

        service.ask(question: "Second question?")
        await waitForIdle(service)

        #expect(cancellations.value == 1)
        // Leave no hanging task behind for the rest of the suite.
        service.cancel()
        #expect(!service.isActive)
    }

    @Test("explicit cancel stops the run and returns to idle")
    func cancelReturnsToIdle() async throws {
        let cancellations = CancellationCounter()
        let service = makeService(answerer: {
            MockLiveQueryAnswerer(chunks: [], finishes: false, cancellationCounter: cancellations)
        }, rows: [Self.finalizedRow(text: "Material.")])

        service.ask(question: "Question?")
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.isActive)

        service.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(cancellations.value == 1)
        #expect(!service.isActive)
        #expect(service.canAsk)
    }

    @Test("chunks accumulate into the answering phase")
    func chunksAccumulate() async {
        let service = makeService(answerer: {
            MockLiveQueryAnswerer(chunks: ["Ada ", "owns ", "the launch."])
        }, rows: [Self.finalizedRow(text: "Material.")])

        service.ask(question: "Who owns it?")
        await waitForIdle(service)

        guard case .answering(let answer) = service.phase else {
            Issue.record("Expected an accumulated answer")
            return
        }
        #expect(answer == "Ada owns the launch.")
        #expect(service.canAsk)
    }

    @Test("asking without finalized content fails before contacting any model")
    func requiresFinalizedContent() async {
        var provisionalOnly = LiveTranscriptFeed()
        provisionalOnly.apply(
            .volatile(.init(
                localeIdentifier: "",
                blocks: [.init(
                    channel: .microphone,
                    text: "draft hypothesis",
                    start: 0,
                    end: 1,
                    words: []
                )]
            )),
            for: .microphone
        )
        let service = makeService(answerer: {
            Issue.record("No model may be contacted without finalized content")
            return MockLiveQueryAnswerer(chunks: [])
        }, rows: provisionalOnly.rows)

        service.ask(question: "Anything?")
        guard case .failed = service.phase else {
            Issue.record("Expected the fixed no-finalized-transcript failure")
            return
        }
        #expect(!service.isActive)
    }

    @Test("transport failures map to fixed sentences without content")
    func transportErrorsStaySanitized() async {
        let service = makeService(answerer: {
            MockLiveQueryAnswerer(chunks: [])
        }, rows: [Self.finalizedRow(text: "Secret agenda item xyzzy.")])

        service.ask(question: "What is on the agenda?")
        await waitForIdle(service)

        guard case .failed(let message) = service.phase else {
            Issue.record("Expected the sanitized invalid-response failure")
            return
        }
        #expect(message == LiveQueryTransportError.invalidResponse.errorDescription)
        #expect(!message.contains("xyzzy"))
    }

    @Test("oversized questions fail locally without any transport run")
    func oversizedQuestionFailsLocally() async {
        let service = makeService(answerer: {
            Issue.record("An oversized question must never reach the transport")
            return MockLiveQueryAnswerer(chunks: ["never"])
        }, rows: [Self.finalizedRow(text: "Material.")])

        service.ask(question: String(repeating: "a", count: 2_001))
        guard case .failed(let message) = service.phase else {
            Issue.record("Expected the too-long-question failure")
            return
        }
        #expect(message.contains("2000"))
        #expect(!service.isActive)
    }

    @Test("context exposes only finalized segments, oldest first")
    func contextSegmentsAreFinalizedOldestFirst() {
        var feed = LiveTranscriptFeed()
        feed.apply(
            .volatile(.init(
                localeIdentifier: "",
                blocks: [.init(
                    channel: .system,
                    text: "provisional",
                    start: 9,
                    end: 10,
                    words: []
                )]
            )),
            for: .system
        )
        feed.apply(
            .final(.init(
                localeIdentifier: "",
                blocks: [
                    .init(channel: .system, text: "later", start: 5, end: 6, words: []),
                    .init(channel: .system, text: "earlier", start: 1, end: 2, words: []),
                ]
            )),
            for: .system
        )

        let context = LiveQueryContext(
            rows: feed.rows,
            meetingTitle: nil,
            participantNames: []
        )
        let segments = context.finalizedSegments
        #expect(segments.map(\.text) == ["earlier", "later"])
        #expect(segments.allSatisfy { $0.isFinal })
        #expect(context.hasFinalizedContent)
    }
}
