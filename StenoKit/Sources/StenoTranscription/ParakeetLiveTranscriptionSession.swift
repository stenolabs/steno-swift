import FluidAudio
import Foundation
import StenoDomain

struct ParakeetLiveUpdate: Sendable {
    let text: String
    let isConfirmed: Bool
    let tokenTimings: [TokenTiming]
}

protocol ParakeetLiveEngine: Sendable {
    var updates: AsyncStream<ParakeetLiveUpdate> { get async }
    func append(_ buffer: AudioBuffer) async
    func finish() async throws -> String
}

actor FluidAudioSlidingEngine: ParakeetLiveEngine {
    private let manager: SlidingWindowAsrManager

    init(modelDirectory: URL, channel: TranscriptionChannel) async throws {
        let models = try await LocalParakeetModelLoader.load(from: modelDirectory)
        let manager = SlidingWindowAsrManager(config: .streaming)
        try await manager.loadModels(models)
        try await manager.startStreaming(
            source: channel == .microphone ? .microphone : .system
        )
        self.manager = manager
    }

    var updates: AsyncStream<ParakeetLiveUpdate> {
        get async {
            let source = await manager.transcriptionUpdates
            return AsyncStream { continuation in
                let task = Task {
                    for await update in source {
                        continuation.yield(ParakeetLiveUpdate(
                            text: update.text,
                            isConfirmed: update.isConfirmed,
                            tokenTimings: update.tokenTimings
                        ))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func append(_ buffer: AudioBuffer) async {
        await manager.streamAudio(buffer.avAudioPCMBuffer)
    }

    func finish() async throws -> String {
        try await manager.finish()
    }
}

public final class ParakeetLiveTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    public let events: AsyncStream<TranscriptionEvent>
    private let engine: any ParakeetLiveEngine
    private let state: ParakeetLiveState
    private let pump: Task<Void, Never>

    init(
        engine: any ParakeetLiveEngine,
        channel: TranscriptionChannel,
        locale: Locale
    ) async {
        self.engine = engine
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        self.events = events
        let state = ParakeetLiveState(
            channel: channel,
            localeIdentifier: locale.identifier,
            continuation: continuation
        )
        self.state = state
        let updates = await engine.updates
        pump = Task {
            for await update in updates {
                await state.consume(update)
            }
        }
    }

    public func append(_ buffer: AudioBuffer) async {
        await engine.append(buffer)
    }

    public func finish() async throws -> TranscriptOutput {
        do {
            let finalText = try await engine.finish()
            // FluidAudio 0.15.5 leaves `transcriptionUpdates` open after
            // `finish()`. Waiting for that stream would therefore keep a
            // completed recording in processing forever. `finish()` returns
            // only after all model windows were processed, so stop the pump
            // and use the manager's authoritative final text.
            pump.cancel()
            await pump.value
            return await state.finish(finalText: finalText)
        } catch {
            pump.cancel()
            await state.terminate()
            throw error
        }
    }
}

private actor ParakeetLiveState {
    let channel: TranscriptionChannel
    let localeIdentifier: String
    let continuation: AsyncStream<TranscriptionEvent>.Continuation
    var confirmed: [TranscriptionWord] = []
    var volatile: [TranscriptionWord] = []
    var didFinish = false

    init(
        channel: TranscriptionChannel,
        localeIdentifier: String,
        continuation: AsyncStream<TranscriptionEvent>.Continuation
    ) {
        self.channel = channel
        self.localeIdentifier = localeIdentifier
        self.continuation = continuation
    }

    func consume(_ update: ParakeetLiveUpdate) {
        guard !didFinish else { return }
        let words = Self.words(from: update.tokenTimings)
        guard !words.isEmpty else { return }
        if update.isConfirmed {
            for word in words where !confirmed.contains(where: {
                abs($0.start - word.start) < 0.001 && abs($0.end - word.end) < 0.001
            }) {
                confirmed.append(word)
            }
            confirmed.sort { $0.start < $1.start }
            volatile = []
            continuation.yield(.final(output(words: confirmed)))
        } else {
            volatile = words
            continuation.yield(.volatile(output(words: confirmed + volatile)))
        }
    }

    func finish(finalText: String = "") -> TranscriptOutput {
        guard !didFinish else { return output(words: confirmed + volatile) }
        didFinish = true
        let normalized = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = output(
            words: confirmed + volatile,
            textOverride: normalized.isEmpty ? nil : normalized
        )
        continuation.yield(.final(result))
        continuation.finish()
        return result
    }

    func terminate() {
        guard !didFinish else { return }
        didFinish = true
        continuation.finish()
    }

    private func output(
        words: [TranscriptionWord],
        textOverride: String? = nil
    ) -> TranscriptOutput {
        guard let first = words.first, let last = words.last else {
            guard let textOverride else {
                return TranscriptOutput(localeIdentifier: localeIdentifier, blocks: [])
            }
            return TranscriptOutput(
                localeIdentifier: localeIdentifier,
                blocks: [TranscriptionBlock(
                    channel: channel,
                    text: textOverride,
                    start: 0,
                    end: 0,
                    words: []
                )]
            )
        }
        let text = textOverride ?? words.map(\.text).joined(separator: " ")
        return TranscriptOutput(
            localeIdentifier: localeIdentifier,
            blocks: [TranscriptionBlock(
                channel: channel,
                text: text,
                start: first.start,
                end: last.end,
                words: words
            )]
        )
    }

    private static func words(from timings: [TokenTiming]) -> [TranscriptionWord] {
        var priorEnd: TimeInterval = 0
        return buildWordTimings(from: timings).map {
            let start = max(priorEnd, $0.startTime)
            let end = max(start, $0.endTime)
            priorEnd = end
            return TranscriptionWord(text: $0.word, start: start, end: end)
        }
    }
}
